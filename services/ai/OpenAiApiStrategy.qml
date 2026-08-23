import QtQuick
import "../../modules/common/functions" as CF

ApiStrategy {
    id: root

    property bool isReasoning: false

    // Streaming tool calls arrive fragmented across deltas (name and
    // arguments split arbitrarily, keyed by index). Accumulate fragments per
    // index; emit the existing functionCall structure once the accumulated
    // arguments form valid JSON. reset() must clear this between requests.
    property var _pendingToolCalls: ({})

    // Accumulation guards: a hostile endpoint must not be able to grow the
    // slot map or fragment buffers without bound. Values give large headroom
    // over legitimate parallel tool calls (single digits) and real argument
    // payloads (<10 KB). Character-based: JS strings are UTF-16, so .length
    // bounds heap directly.
    readonly property int maxToolCallSlots: 64         // tracked indices per request
    readonly property int maxFunctionNameLength: 1024  // chars, per tool call
    readonly property int maxFunctionArgsLength: 262144 // chars (~512 KB heap), per tool call

    function buildEndpoint(model: AiModel): string {
        // console.log("[AI] Endpoint: " + model.endpoint);
        return CF.StringUtils.shellDoubleQuoteEscape(model.endpoint);
    }

    function buildRequestData(model: AiModel, messages, systemPrompt: string, temperature: real, tools: list<var>, filePath: string) {
        let baseData = {
            "model": model.model,
            "messages": [
                {role: "system", content: systemPrompt},
                ...messages.map(message => {
                    return {
                        "role": message.role,
                        "content": message.rawContent,
                    }
                }),
            ],
            "stream": true,
            "tools": tools,
            "temperature": temperature,
        };
        // Multimodal input (vision-capable models only reach this point —
        // text-only models are filtered in makeRequest): convert the last
        // user message to a content array carrying the image as an inline
        // base64 data URL. The placeholder is spliced by
        // finalizeScriptContent() so bash expands the runtime-computed value.
        const trimmedPath = filePath && filePath.length > 0 ? CF.FileUtils.trimFileProtocol(filePath) : "";
        if (trimmedPath.length > 0) {
            const msgs = baseData.messages;
            for (let i = msgs.length - 1; i >= 0; i--) {
                if (msgs[i].role === "user") {
                    msgs[i].content = [
                        { type: "text", text: msgs[i].content },
                        { type: "image_url", image_url: { url: "{{ imageDataUrl }}" } },
                    ];
                    break;
                }
            }
        }
        return model.extraParams ? Object.assign({}, baseData, model.extraParams) : baseData;
    }

    function buildScriptFileSetup(filePath: string): string {
        let content = "";
        content += `IMAGE_PATH='${CF.StringUtils.shellSingleQuoteEscape(filePath)}'\n`;
        content += 'if [ ! -f "$IMAGE_PATH" ] || [ ! -s "$IMAGE_PATH" ]; then\n';
        content += '  printf \'{"error":{"message":"Attachment failed: file not found."}}\\n,\\n\'\n';
        content += '  exit 0\n';
        content += 'fi\n';
        content += 'IMAGE_SIZE=$(wc -c < "$IMAGE_PATH")\n';
        content += 'if [ "$IMAGE_SIZE" -gt 14000000 ]; then\n';
        content += '  printf \'{"error":{"message":"Image too large (max 14 MB)."}}\\n,\\n\'\n';
        content += '  exit 0\n';
        content += 'fi\n';
        content += 'MIME_TYPE=$(file -b --mime-type "$IMAGE_PATH")\n';
        content += 'case "$MIME_TYPE" in image/png|image/jpeg|image/webp|image/gif) ;; *)\n';
        content += '  printf \'{"error":{"message":"Unsupported attachment type."}}\\n,\\n\'\n';
        content += '  exit 0\n';
        content += ';; esac\n';
        content += 'IMAGE_DATA_URL="data:${MIME_TYPE};base64,$(base64 -w0 "$IMAGE_PATH")"\n';
        return content;
    }

    function finalizeScriptContent(scriptContent: string): string {
        // Quote-splice: break out of curl's single-quoted --data so bash can
        // expand the runtime-computed data URL (same mechanism Gemini uses).
        return scriptContent.replace('"{{ imageDataUrl }}"', '\'\"$IMAGE_DATA_URL\"\'');
    }

    function buildAuthorizationHeader(apiKeyEnvVarName: string): string {
        return `-H "Authorization: Bearer \$\{${apiKeyEnvVarName}\}"`;
    }

    function parseResponseLine(line, message) {
        // Remove 'data: ' prefix if present and trim whitespace
        let cleanData = line.trim();
        if (cleanData.startsWith("data:")) {
            cleanData = cleanData.slice(5).trim();
        }

        // console.log("[AI] OpenAI: Data:", cleanData);
        
        // Handle special cases
        if (!cleanData || cleanData.startsWith(":")) return {};
        if (cleanData === "[DONE]") {
            return { finished: true };
        }
        
        // Real stuff
        try {
            const dataJson = JSON.parse(cleanData);

            // Error response handling
            if (dataJson.error) {
                const errorMsg = `**Error**: ${dataJson.error.message || JSON.stringify(dataJson.error)}`;
                message.rawContent += errorMsg;
                message.content += errorMsg;
                return { finished: true };
            }

            let newContent = "";

            // Tool calls (fragmented across deltas, keyed by index)
            if (dataJson.choices[0]?.delta?.tool_calls) {
                const fragments = dataJson.choices[0].delta.tool_calls;
                for (let c = 0; c < fragments.length; c++) {
                    const tc = fragments[c];
                    const idx = tc.index ?? 0;
                    // Slot-count guard: ignore indices beyond the cap. Such
                    // slots are dropped entirely — they can never reach the
                    // approval/execution flow.
                    if (idx < 0 || idx >= root.maxToolCallSlots) continue;
                    if (!root._pendingToolCalls[idx]) {
                        root._pendingToolCalls[idx] = { id: "", name: "", args: "", done: false };
                    }
                    const slot = root._pendingToolCalls[idx];
                    if (slot.done) continue; // Ignore stray fragments after emit
                    if (tc.id && slot.id.length === 0) slot.id = tc.id;
                    // Length guards: truncate fragments at the caps. A slot
                    // whose arguments were truncated by the cap can no longer
                    // form valid JSON, so it is silently never emitted (no
                    // partial tool call can reach approval or execution).
                    if (tc.function?.name && slot.name.length < root.maxFunctionNameLength) {
                        const roomN = root.maxFunctionNameLength - slot.name.length;
                        slot.name += tc.function.name.slice(0, roomN);
                    }
                    if (tc.function?.arguments && slot.args.length < root.maxFunctionArgsLength) {
                        const roomA = root.maxFunctionArgsLength - slot.args.length;
                        slot.args += tc.function.arguments.slice(0, roomA);
                    }

                    if (slot.name.length > 0 && slot.args.length > 0) {
                        try {
                            const parsedArgs = JSON.parse(slot.args);
                            slot.done = true;
                            message.functionName = slot.name;
                            message.functionCall = slot.name;
                            return { functionCall: { name: slot.name, args: parsedArgs, id: slot.id } };
                        } catch (e) {
                            // Arguments not complete yet — keep accumulating
                        }
                    }
                }
                return {};
            }

            const responseContent = dataJson.choices[0]?.delta?.content || dataJson.message?.content;
            const responseReasoning = dataJson.choices[0]?.delta?.reasoning || dataJson.choices[0]?.delta?.reasoning_content;

            if (responseContent && responseContent.length > 0) {
                if (isReasoning) {
                    isReasoning = false;
                    const endBlock = "\n\n</think>\n\n";
                    message.content += endBlock;
                    message.rawContent += endBlock;
                }
                newContent = responseContent;
            } else if (responseReasoning && responseReasoning.length > 0) {
                if (!isReasoning) {
                    isReasoning = true;
                    const startBlock = "\n\n<think>\n\n";
                    message.rawContent += startBlock;
                    message.content += startBlock;
                }
                newContent = responseReasoning;
            }

            message.content += newContent;
            message.rawContent += newContent;

            // Usage metadata
            if (dataJson.usage) {
                return {
                    tokenUsage: {
                        input: dataJson.usage.prompt_tokens ?? -1,
                        output: dataJson.usage.completion_tokens ?? -1,
                        total: dataJson.usage.total_tokens ?? -1
                    }
                };
            }

            if (dataJson.done) {
                return { finished: true };
            }
            
        } catch (e) {
            console.log("[AI] OpenAI: Could not parse line: ", e);
            message.rawContent += line;
            message.content += line;
        }
        
        return {};
    }
    
    function onRequestFinished(message) {
        // OpenAI format doesn't need special finish handling
        return {};
    }
    
    function reset() {
        isReasoning = false;
        root._pendingToolCalls = ({});
    }

}
