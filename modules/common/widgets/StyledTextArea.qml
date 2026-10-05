import ".."
import QtQuick
import QtQuick.Controls

/**
 * Does not include visual layout, but includes the easily neglected colors.
 */
TextArea {
    id: root

    renderType: Text.NativeRendering
    selectedTextColor: Appearance.m3colors.m3onSecondaryContainer
    selectionColor: Appearance.colors.colSecondaryContainer
    placeholderTextColor: Appearance.m3colors.m3outline
    color: Appearance.colors.colOnLayer0
    Menu {
        id: editContextMenu

        parent: root
        implicitWidth: 190
        padding: 5

        delegate: MenuItem {
            id: menuItem

            implicitHeight: 34

            contentItem: Text {
                text: menuItem.text
                color: menuItem.enabled ? Appearance.colors.colOnLayer1 : Appearance.colors.colOnLayer1Inactive
                font.family: Appearance.font.family.main
                font.pixelSize: Appearance.font.pixelSize.small
                verticalAlignment: Text.AlignVCenter
                leftPadding: 9
            }

            background: Rectangle {
                radius: Appearance.rounding.small || 4
                color: menuItem.highlighted ? Appearance.m3colors.m3surfaceContainerHighest : "transparent"
            }
        }

        background: Rectangle {
            color: Appearance.m3colors.m3surfaceContainerHigh
            border.color: Appearance.m3colors.m3outlineVariant
            radius: Appearance.rounding.small || 4
        }

        MenuItem {
            text: qsTr("Undo")
            enabled: root.canUndo
            onTriggered: root.undo()
        }
        MenuItem {
            text: qsTr("Redo")
            enabled: root.canRedo
            onTriggered: root.redo()
        }
        MenuSeparator {
            contentItem: Rectangle {
                implicitHeight: 1
                color: Appearance.colors.colOutlineVariant
            }
        }
        MenuItem {
            text: qsTr("Cut")
            enabled: !root.readOnly && root.selectedText.length > 0
            onTriggered: root.cut()
        }
        MenuItem {
            text: qsTr("Copy")
            enabled: root.selectedText.length > 0
            onTriggered: root.copy()
        }
        MenuItem {
            text: qsTr("Paste")
            enabled: !root.readOnly && root.canPaste
            onTriggered: root.paste()
        }
        MenuItem {
            text: qsTr("Select All")
            enabled: root.length > 0
            onTriggered: root.selectAll()
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        preventStealing: true
        onClicked: (mouse) => editContextMenu.popup(mouse.x, mouse.y)
    }

    font {
        family: Appearance.font.family.main
        pixelSize: Appearance?.font.pixelSize.small ?? 15
        hintingPreference: Font.PreferFullHinting
        variableAxes: Appearance.font.variableAxes.main
    }
}
