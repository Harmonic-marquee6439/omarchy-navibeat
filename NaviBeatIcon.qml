import QtQuick
import qs.Commons

// A waveform, drawn as rectangles rather than a font glyph. Same reasoning as
// the first-party TailscaleIcon: a glyph depends on the particular Nerd Font
// build and can land as a tofu box. One colour, always from the theme.
//
// **Bars grow from the middle, not from the floor.** An equalizer anchored to
// its baseline puts all its weight at the bottom of the icon box, so next to
// text that is centred on its own line it reads as sitting too low even when
// the box itself is centred perfectly. Growing symmetrically about the centre
// keeps the optical mass where the eye expects it at every amplitude.
//
// The bars only move while something is playing. A permanently animating icon
// in a bar is noise; one that moves exactly when audio is running is a status
// light you can read peripherally.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property bool playing: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real barWidth: Math.max(1, iconSize * 0.13)
  readonly property real gap: Math.max(1, iconSize * 0.10)

  Row {
    anchors.centerIn: parent
    spacing: root.gap

    // Amplitudes are deliberately uneven and the periods are coprime-ish, so
    // the five bars never settle into a visible marching pattern.
    Bar { minScale: 0.30; maxScale: 0.62; period: 700 }
    Bar { minScale: 0.55; maxScale: 1.00; period: 520 }
    Bar { minScale: 0.38; maxScale: 0.80; period: 610 }
    Bar { minScale: 0.62; maxScale: 0.94; period: 470 }
    Bar { minScale: 0.28; maxScale: 0.58; period: 660 }
  }

  component Bar: Item {
    id: barItem
    property real minScale: 0.4
    property real maxScale: 1.0
    property int period: 600

    width: root.barWidth
    height: root.iconSize

    Rectangle {
      width: parent.width
      // At rest the waveform holds a readable amplitude rather than collapsing
      // to a line, so the icon still says "audio" when playback is paused.
      height: root.iconSize * (root.playing ? barItem.minScale : barItem.minScale * 1.15)
      radius: width / 2
      color: root.color
      anchors.verticalCenter: parent.verticalCenter

      SequentialAnimation on height {
        running: root.playing
        loops: Animation.Infinite
        NumberAnimation {
          to: root.iconSize * barItem.maxScale
          duration: barItem.period
          easing.type: Easing.InOutSine
        }
        NumberAnimation {
          to: root.iconSize * barItem.minScale
          duration: barItem.period
          easing.type: Easing.InOutSine
        }
      }
    }
  }
}
