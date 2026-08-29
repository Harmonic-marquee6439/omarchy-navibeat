import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Now playing in the bar, with the parts only the server knows.
//
// Playback is not reimplemented: the first-party `omarchy.media` service already
// owns MPRIS, picks the active player and exposes the transport actions, so this
// widget consumes it the way the built-in media widget does. What it adds is
// everything MPRIS has no concept of — whether the track is starred, its rating,
// its real format and bitrate, and what is playing on your other devices.
//
// **Following another device.** Click a session under "playing elsewhere" and
// the bar follows it instead: the Mac's track scrolls in the top bar with its
// artwork and a live progress bar. It is deliberately read-only, because the
// Subsonic protocol has no command that controls another client — NaviBeat's own
// handoff works by the *taken-over* device noticing and yielding, not by anyone
// driving anyone. Starring still works while following, because that is a
// server-side write and has nothing to do with who is playing.
//
// Like the built-in widget, it disappears entirely when nothing is playing here
// and nothing is being followed.
BarWidget {
  id: root
  moduleName: "nenadjokic.navibeat"

  readonly property string script: Qt.resolvedUrl("bin/omarchy-navibeat").toString().replace("file://", "")

  readonly property var mediaService: bar?.shell?.firstPartyServiceFor("omarchy.media")
  readonly property var activePlayer: mediaService ? mediaService.activePlayer : null

  readonly property bool hasLocal: activePlayer !== null && (activePlayer.trackTitle || activePlayer.trackArtist)

  // Is the music app itself running, whether or not it has a track loaded?
  //
  // The built-in media widget appears only once something has metadata, which
  // is right for a generic now-playing widget but wrong here: this one is the
  // app's own bar presence, so it should be there from the moment the app is
  // opened, before anything is played. Every player is checked rather than just
  // the active one, because an idle app is not what `selectActivePlayer` picks
  // when something else is already playing.
  readonly property string appPlayer: String(setting("appPlayer", "navibeat")).toLowerCase()
  readonly property bool appRunning: {
    if (!root.mediaService || root.appPlayer === "") return false
    var list = root.mediaService.players || []
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!p) continue
      var de = String(p.desktopEntry || "").toLowerCase()
      var id = String(p.identity || "").toLowerCase()
      if (de === root.appPlayer || id === root.appPlayer) return true
    }
    return false
  }
  readonly property string localTitle: activePlayer ? (activePlayer.trackTitle || "") : ""
  readonly property string localArtist: activePlayer ? (activePlayer.trackArtist || "") : ""
  readonly property string localAlbum: activePlayer && activePlayer.trackAlbum ? activePlayer.trackAlbum : ""
  readonly property bool localPlaying: activePlayer ? activePlayer.isPlaying === true : false

  readonly property bool showLabel: setting("showLabel", true) === true
  // `omarchy bar set` stores whatever the shell wrote, and that can be a string
  // ("120"), so this is coerced rather than trusted to compare numerically.
  readonly property real maxLabelWidth: Math.max(60, Number(setting("maxLabelWidth", 180)) || 180)
  // Which client name this machine reports to the server. NaviBeat's own client
  // names are fixed per platform ("NaviBeat Linux", "NaviBeat Android",
  // "NaviBeat Windows", …), and sessions carrying this one are us — without
  // this filter the panel lists the very track playing on this desk under
  // "playing elsewhere".
  readonly property string localDevice: String(setting("localDevice", "NaviBeat Linux"))

  // ---------------------------------------------------------------- state

  // Server record for whatever is on screen: the local track once resolved, or
  // the followed session's track. One property, so the panel has one code path.
  property var song: ({})
  property string coverPath: ""
  property var sessions: []
  property bool serverOk: true

  // The device being followed, by client name. Empty means "this machine".
  property string followedPlayer: ""
  readonly property bool following: followedPlayer !== ""

  // The followed session as the server currently reports it, or null when that
  // device has stopped reporting.
  readonly property var liveSession: {
    if (!root.following) return null
    for (var i = 0; i < root.sessions.length; i++)
      if (String(root.sessions[i].player) === root.followedPlayer) return root.sessions[i]
    return null
  }

  // The last session seen for the followed device, kept so that following
  // survives the device going quiet.
  property var lastSession: null

  // What the panel draws while following. Falls back to the remembered session
  // rather than to this machine: **choosing what to watch is a click, never
  // something the widget decides.** A device that pauses, sleeps or drops off
  // the network stops reporting within a minute, and silently snapping back to
  // local playback would move the view out from under you.
  readonly property var followed: liveSession || lastSession
  readonly property bool followedStale: following && liveSession === null

  // Other people's devices. Anything reporting our own client name is this
  // machine, however many local players are running under it.
  readonly property var elsewhere: {
    var out = []
    for (var i = 0; i < root.sessions.length; i++) {
      var s = root.sessions[i]
      if (String(s.player) !== root.localDevice) out.push(s)
    }
    return out
  }

  // ------------------------------------------------------- what to display

  readonly property bool active: following ? true : (hasLocal || appRunning)
  readonly property string viewTitle: following ? (followed ? String(followed.title) : "") : localTitle
  readonly property string viewArtist: following ? (followed ? String(followed.artist) : "") : localArtist
  readonly property string viewAlbum: following ? (followed ? String(followed.album) : "") : localAlbum
  // "starting" is a real state in NaviBeat's protocol: a client that has just
  // been handed a track reports it before its first progress tick.
  readonly property bool viewPlaying: following
      ? (!followedStale && followed
         ? (followed.state === "playing" || followed.state === "starting") : false)
      : localPlaying

  readonly property string viewSongId: {
    if (following) return followed && followed.id ? String(followed.id) : ""
    return song && song.id ? String(song.id) : ""
  }
  readonly property bool resolved: viewSongId !== ""

  readonly property string quality: {
    var src = following ? followed : song
    if (!src) return ""
    var bits = []
    if (src.suffix) bits.push(String(src.suffix))
    if (src.bitRate) bits.push(src.bitRate + " kbps")
    return bits.join(" · ")
  }

  // Position while following. The server reports it only per poll, so it is
  // advanced locally in between and re-anchored on every refresh; without that
  // the bar would look frozen for eight seconds at a time.
  property real anchorMs: 0
  property real anchorAt: 0
  readonly property real viewDurationMs: {
    var src = following ? followed : null
    return src && src.duration ? src.duration * 1000 : 0
  }
  property real tick: 0
  readonly property real viewPositionMs: {
    void root.tick
    if (!root.following || !root.followed) return 0
    var base = root.anchorMs
    if (root.viewPlaying) base += (Date.now() - root.anchorAt)
    return Math.max(0, Math.min(base, root.viewDurationMs || base))
  }

  // Artwork mode, cycled by clicking the cover: "hi" → "pixel" → "mono".
  //
  // The pixel look is NaviBeat's TUI cover: it samples the art to 28x28 and
  // paints it in terminal half-blocks, so asking the server for a 28px cover
  // and drawing it with smoothing off reproduces that exactly rather than
  // approximating it with a blur filter.
  //
  // "mono" is that same 28px cover tinted to the bar's own foreground, so the
  // artwork stops being the one thing in the bar that ignores the theme.
  property string artMode: "hi"
  readonly property bool pixelated: artMode !== "hi"
  readonly property bool monoArt: artMode === "mono"
  readonly property int coverPx: pixelated ? 28 : 256

  property bool popupOpen: false
  function close() { popupOpen = false }

  visible: active
  implicitWidth: active ? row.implicitWidth + Style.space(14) : 0
  implicitHeight: barSize

  // --------------------------------------------------------------- actions

  // MPRIS emits metadata in bursts while a track loads, and each lookup is a
  // network round trip. Settling first means one search per track, not five.
  Timer {
    id: resolveDebounce
    interval: 700
    onTriggered: root.resolve()
  }

  onLocalTitleChanged: root.localTrackChanged()
  onLocalArtistChanged: root.localTrackChanged()

  function localTrackChanged() {
    if (root.following) return
    root.song = ({})
    root.coverPath = ""
    if (root.localTitle !== "") resolveDebounce.restart()
  }

  // NaviBeat puts the Navidrome song id straight into `mpris:trackid`
  // (/app/navibeat/track/<id>). When it is there we know the track exactly and
  // the fuzzy search is skipped entirely — no chance of starring a cover
  // version by accident. Other players do not carry it, hence the fallback.
  readonly property string mprisSongId: {
    if (!root.activePlayer) return ""
    var m = root.activePlayer.metadata
    var raw = m ? (m["mpris:trackid"] || "") : ""
    var hit = /\/track\/([A-Za-z0-9_-]+)$/.exec(String(raw))
    return hit ? hit[1] : ""
  }

  function resolve() {
    if (root.following || root.localTitle === "") return
    if (root.mprisSongId !== "") {
      if (songProcess.running) return
      songProcess.command = [root.script, "song", root.mprisSongId]
      songProcess.running = true
      root.loadCover(root.mprisSongId)
      return
    }
    if (findProcess.running) return
    findProcess.command = [root.script, "find",
                           root.localArtist + "|" + root.localAlbum + "|" + root.localTitle]
    findProcess.running = true
  }

  function loadCover(id) {
    if (!id || coverProcess.running) return
    coverProcess.command = [root.script, "cover", String(id), String(root.coverPx)]
    coverProcess.running = true
  }

  // The choice has to outlive a restart, and the shell's widget settings are
  // read-only from QML, so it is kept in the backend's own prefs file.
  function toggleArt() {
    var order = ["hi", "pixel", "mono"]
    var next = order[(order.indexOf(root.artMode) + 1) % order.length]
    var sizeChanged = (next === "hi") !== (root.artMode === "hi")
    root.artMode = next
    prefWriteProcess.command = [root.script, "pref", "art", next]
    prefWriteProcess.running = true
    // pixel and mono share the same 28px download; only crossing to or from
    // "hi" needs a different size fetched.
    if (sizeChanged) {
      root.coverPath = ""
      root.loadCover(root.viewSongId || (root.followed ? root.followed.coverArt : ""))
    }
  }

  function refreshSong() {
    // While following, the id comes from the session rather than from
    // `song`, which is precisely what is being (re)fetched here.
    var id = root.following
      ? (root.followed && root.followed.id ? String(root.followed.id) : "")
      : root.viewSongId
    if (!id || songProcess.running) return
    songProcess.command = [root.script, "song", id]
    songProcess.running = true
  }

  function toggleStar() {
    if (!root.resolved || writeProcess.running) return
    writeProcess.command = [root.script, root.song.starred ? "unstar" : "star", root.viewSongId]
    writeProcess.running = true
  }

  function setRating(value) {
    if (!root.resolved || writeProcess.running) return
    // Clicking the star that is already the rating clears it — otherwise there
    // is no way back to "unrated" without a separate control.
    var next = (root.song.rating === value) ? 0 : value
    writeProcess.command = [root.script, "rate", root.viewSongId, String(next)]
    writeProcess.running = true
  }

  function loadStatus() {
    if (statusProcess.running) return
    statusProcess.command = [root.script, "status"]
    statusProcess.running = true
  }

  function follow(player) {
    root.followedPlayer = String(player)
    root.lastSession = null
    root.song = ({})
    root.coverPath = ""
    root.anchorMs = 0
    root.anchorAt = Date.now()
    root.loadStatus()
  }

  function unfollow() {
    root.followedPlayer = ""
    root.lastSession = null
    root.song = ({})
    root.coverPath = ""
    root.localTrackChanged()
  }

  // While following, the session list *is* the data source, so it is polled
  // whether or not the panel is open — the bar has to keep up on its own.
  // Eight seconds is a passive display; NaviBeat polls at three because it is
  // deciding whether to stop your music, which is a different kind of urgency.
  Timer {
    interval: 8000
    running: root.following || root.popupOpen
    repeat: true
    triggeredOnStart: true
    onTriggered: root.loadStatus()
  }

  Timer {
    interval: 500
    running: root.following && root.viewPlaying && root.popupOpen
    repeat: true
    onTriggered: root.tick = root.tick + 1
  }

  Process {
    id: findProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: findOut
      waitForEnd: true
      onStreamFinished: {
        var d = {}
        try { d = JSON.parse(findOut.text) } catch (e) { d = {} }
        if (!root.following) {
          root.song = d
          if (d && d.id) root.loadCover(d.id)
        }
      }
    }
  }

  Process {
    id: songProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: songOut
      waitForEnd: true
      onStreamFinished: {
        try { root.song = JSON.parse(songOut.text) } catch (e) {}
      }
    }
  }

  Process {
    id: coverProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: coverOut
      waitForEnd: true
      onStreamFinished: root.coverPath = String(coverOut.text || "").trim()
    }
  }

  // A write is only believed once the server has confirmed it: re-read the song
  // rather than assuming the star flipped, so the panel can never show a state
  // the server does not actually hold.
  Process {
    id: writeProcess
    running: false
    command: []
    onExited: root.refreshSong()
  }

  Process {
    id: prefWriteProcess
    running: false
    command: []
  }

  Process {
    id: prefReadProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: prefOut
      waitForEnd: true
      onStreamFinished: {
        try {
          var v = String(JSON.parse(prefOut.text).art || "hi")
          root.artMode = (v === "pixel" || v === "mono") ? v : "hi"
        } catch (e) {}
      }
    }
  }

  Component.onCompleted: {
    prefReadProcess.command = [root.script, "pref", "art"]
    prefReadProcess.running = true
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
      onStreamFinished: {
        var d = {}
        try { d = JSON.parse(statusOut.text) } catch (e) { d = {} }
        root.serverOk = d.ok === true
        root.sessions = d.elsewhere || []

        if (root.following && root.liveSession) {
          root.lastSession = root.liveSession
          // Re-anchor the progress clock on every poll, and pull the star and
          // rating for whatever the followed device moved on to.
          root.anchorMs = root.followed.positionMs ? Number(root.followed.positionMs) : 0
          root.anchorAt = Date.now()

          // Reconcile on EVERY poll rather than only on the edge where the id
          // changes. A single missed attempt — the fetch skipped because a
          // process was already running — used to leave the panel showing an
          // empty heart for a track the server has starred, and nothing ever
          // tried again. Comparing state instead of watching for a transition
          // means the next poll repairs it.
          var want = String(root.followed.id || "")
          if (want !== "" && String(root.song.id || "") !== want) {
            if (root.song.id !== undefined) root.song = ({})
            root.refreshSong()
          }
          if (want !== "" && root.coverPath === "")
            root.loadCover(root.followed.coverArt || want)
        }
      }
    }
  }

  onPopupOpenChanged: if (popupOpen) { loadStatus(); if (resolved && !following) refreshSong() }

  IpcHandler {
    target: "nenadjokic.navibeat"
    function toggle(): void { root.popupOpen = !root.popupOpen }
    function show(): void { root.popupOpen = true }
    function hide(): void { root.popupOpen = false }
    function refresh(): string { root.loadStatus(); return "ok" }
    function follow(player: string): string { root.follow(player); return "ok" }
    function unfollow(): string { root.unfollow(); return "ok" }
    function star(): string { root.toggleStar(); return "ok" }
    function art(): string { root.toggleArt(); return root.artMode }
    // Why the widget is (or is not) in the bar right now. Cheap to expose and
    // the only way to tell "the app is running" apart from "a track is loaded"
    // without guessing from the outside.
    function probe(): string {
      return JSON.stringify({
        visible: root.active,
        appRunning: root.appRunning,
        hasTrack: root.hasLocal,
        appPlayer: root.appPlayer,
        players: (root.mediaService && root.mediaService.players
                  ? root.mediaService.players.length : 0),
        following: root.followedPlayer
      })
    }
  }

  // ------------------------------------------------------------------- bar

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    NaviBeatIcon {
      anchors.verticalCenter: parent.verticalCenter
      iconSize: Style.font.icon
      color: root.bar ? root.bar.foreground : Color.foreground
      playing: root.viewPlaying
      // A followed device is dimmed: it is somebody else's playback, and the
      // bar should say so without a second glyph.
      opacity: root.following ? 0.65 : 1.0
    }

    Item {
      id: scrollClip
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showLabel && !root.bar.vertical && root.active
      width: visible ? Math.min(root.maxLabelWidth, labelText.implicitWidth) : 0
      height: labelText.implicitHeight
      clip: true

      Text {
        id: labelText
        text: root.viewArtist ? (root.viewArtist + " — " + root.viewTitle) : root.viewTitle
        color: root.bar ? root.bar.foreground : Color.foreground
        opacity: root.following ? 0.8 : 1.0
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body

        property bool needsScroll: implicitWidth > scrollClip.width

        NumberAnimation on x {
          running: labelText.needsScroll && !root.popupOpen && !root.bar.vertical
          loops: Animation.Infinite
          from: scrollClip.width
          to: -labelText.implicitWidth
          duration: Math.max(6000, labelText.implicitWidth * 25)
          easing.type: Easing.Linear
        }

        onNeedsScrollChanged: if (!needsScroll) x = 0
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      // Transport is meaningless while following somebody else's device, so
      // every button just opens the panel there.
      if (root.following) { root.popupOpen = !root.popupOpen; return }
      if (!root.activePlayer) return
      if (mouse.button === Qt.MiddleButton) root.act("next")
      else if (mouse.button === Qt.RightButton) root.act("playPause")
      else root.popupOpen = !root.popupOpen
    }
    onWheel: function(wheel) {
      if (root.following || !root.activePlayer) return
      root.act(wheel.angleDelta.y > 0 ? "previous" : "next")
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.active
      ? ((root.following ? root.followedPlayer + ":  " : "")
         + root.viewTitle + (root.viewArtist ? " — " + root.viewArtist : "")
         + (root.quality ? "  ·  " + root.quality : ""))
      : "")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  function act(action) {
    if (!root.mediaService || root.following) return
    root.mediaService.runAction(action, false, root.mediaService.playerKey(root.activePlayer))
  }

  // ----------------------------------------------------------------- popup

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
    readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      // Says whose playback this is, and how to get back. Only ever visible
      // while following, so the normal case carries no extra chrome.
      Row {
        width: parent.width
        visible: root.following
        spacing: Style.space(6)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          // Says plainly when the device has gone quiet, instead of leaving a
          // frozen track looking live. The view still does not move on its own.
          text: "FOLLOWING " + root.followedPlayer.toUpperCase()
                + (root.followedStale ? " · IDLE" : "")
          color: Qt.darker(popup.fg, 1.4)
          font.family: popup.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Item { width: parent.width - 200; height: 1 }

        Text {
          id: backLink
          anchors.verticalCenter: parent.verticalCenter
          text: "BACK"
          color: popup.fg
          opacity: backMouse.containsMouse ? 1.0 : 0.5
          font.family: popup.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true

          Behavior on opacity { NumberAnimation { duration: 120 } }

          MouseArea {
            id: backMouse
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.unfollow()
          }
        }
      }

      Row {
        spacing: Style.space(10)
        width: parent.width

        BorderSurface {
          width: Style.space(64)
          height: Style.space(64)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(popup.fg, Color.accent)
          borderSpec: Border.controlSpec("normal", popup.fg, Color.accent)

          // The server's cover is preferred over the one MPRIS advertises: it
          // is the full-resolution original rather than whatever thumbnail the
          // player handed out — and while following there is no MPRIS at all.
          Image {
            id: coverImage
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            // Nearest-neighbour in pixel mode: the 28px cover has to stay
            // blocky, and any smoothing would just turn it back into a blur.
            smooth: !root.pixelated
            mipmap: false
            source: root.coverPath !== "" ? "file://" + root.coverPath
                  : (!root.following && root.activePlayer && root.activePlayer.trackArtUrl
                     ? root.activePlayer.trackArtUrl : "")
            visible: source !== ""
          }

          MultiEffect {
            anchors.fill: coverImage
            source: coverImage
            visible: root.monoArt && coverImage.visible
            // Colorization only. MultiEffect applies it *before* saturation, so
            // adding `saturation: -1` here does not flatten the cover first — it
            // strips the tint that colorization just applied and leaves plain
            // greyscale. Colorization on its own already keeps the source's
            // luminance and takes its hue from the theme, which is the whole
            // point: change the Omarchy theme and the artwork follows.
            colorization: 1.0
            colorizationColor: popup.fg
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleArt()
          }

          Text {
            anchors.centerIn: parent
            visible: root.coverPath === ""
                     && (root.following || !root.activePlayer || !root.activePlayer.trackArtUrl)
            text: "󰝚"
            color: popup.fg
            font.family: popup.fontFamily
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          spacing: Style.space(4)
          width: parent.width - Style.space(74)

          Text {
            text: root.viewTitle || "Nothing playing"
            color: popup.fg
            font.family: popup.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            text: root.viewArtist
            color: Qt.darker(popup.fg, 1.3)
            font.family: popup.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          Text {
            text: root.viewAlbum
            color: Qt.darker(popup.fg, 1.6)
            font.family: popup.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          // Format, bitrate and play count: the things that tell you whether
          // you are hearing the good copy, which is the point of running your
          // own library.
          Text {
            text: {
              var bits = []
              if (root.quality) bits.push(root.quality)
              if (root.song && root.song.playCount)
                bits.push(root.song.playCount + (root.song.playCount === 1 ? " play" : " plays"))
              return bits.join("  ·  ")
            }
            color: Qt.darker(popup.fg, 1.6)
            font.family: popup.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }
      }

      // Progress, only while following: locally MPRIS already drives a
      // position and the transport row is right there, but a followed device
      // has no other way to show that it is actually moving.
      Column {
        width: parent.width
        visible: root.following && root.viewDurationMs > 0
        spacing: Style.space(3)

        Rectangle {
          width: parent.width
          height: Math.max(2, Style.space(3))
          radius: height / 2
          color: Qt.rgba(popup.fg.r, popup.fg.g, popup.fg.b, 0.18)

          Rectangle {
            width: parent.width * (root.viewDurationMs > 0
                   ? Math.min(1, root.viewPositionMs / root.viewDurationMs) : 0)
            height: parent.height
            radius: height / 2
            color: popup.fg
          }
        }

        Text {
          width: parent.width
          text: {
            function clock(ms) {
              var t = Math.max(0, Math.floor(ms / 1000))
              var m = Math.floor(t / 60)
              var s = t % 60
              return m + ":" + (s < 10 ? "0" : "") + s
            }
            if (root.followedStale)
              return clock(root.viewPositionMs) + " / " + clock(root.viewDurationMs)
                     + "   " + root.followedPlayer + " stopped reporting"
            return clock(root.viewPositionMs) + " / " + clock(root.viewDurationMs)
                   + (root.viewPlaying ? "" : "   paused")
          }
          color: Qt.darker(popup.fg, 1.6)
          font.family: popup.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Transport is hidden rather than disabled while following: the protocol
      // has no way to control another client, and a row of dead buttons reads
      // like a bug.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)
        visible: !root.following

        Button {
          iconText: "󰒮"
          foreground: popup.fg
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.activePlayer && root.activePlayer.canGoPrevious
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.act("previous")
        }

        Button {
          iconText: root.localPlaying ? "󰏤" : "󰐊"
          foreground: popup.fg
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: root.activePlayer && (root.activePlayer.canTogglePlaying
                                         || root.activePlayer.canPlay
                                         || root.activePlayer.canPause)
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.act("playPause")
        }

        Button {
          iconText: "󰒭"
          foreground: popup.fg
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.activePlayer && root.activePlayer.canGoNext
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.act("next")
        }
      }

      PanelSeparator {
        visible: root.resolved
        foreground: popup.fg
      }

      // The server-side row. This is the part a generic MPRIS widget cannot
      // have: both controls write to Navidrome, so a star set here is already
      // set on the phone and the Apple TV — and it works on a followed device
      // too, since starring has nothing to do with who is playing.
      Row {
        width: parent.width
        visible: root.resolved
        spacing: Style.space(10)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.song && root.song.starred ? "♥" : "♡"
          color: popup.fg
          opacity: heartMouse.containsMouse ? 1.0 : ((root.song && root.song.starred) ? 0.95 : 0.5)
          font.family: popup.fontFamily
          font.pixelSize: Style.font.subtitle

          Behavior on opacity { NumberAnimation { duration: 120 } }

          MouseArea {
            id: heartMouse
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleStar()
          }
        }

        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Repeater {
            model: 5
            Text {
              required property int index
              readonly property int value: index + 1
              readonly property int current: root.song && root.song.rating ? root.song.rating : 0
              text: current >= value ? "★" : "☆"
              color: popup.fg
              opacity: starMouse.containsMouse ? 1.0 : (current >= value ? 0.95 : 0.4)
              font.family: popup.fontFamily
              font.pixelSize: Style.font.body

              Behavior on opacity { NumberAnimation { duration: 120 } }

              MouseArea {
                id: starMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setRating(parent.value)
              }
            }
          }
        }
      }

      Text {
        width: parent.width
        visible: !root.serverOk
        text: "Navidrome is not reachable — stars, ratings and other devices are unavailable."
        color: Qt.darker(popup.fg, 1.5)
        wrapMode: Text.WordWrap
        font.family: popup.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelSeparator {
        visible: root.elsewhere.length > 0
        foreground: popup.fg
      }

      Column {
        width: parent.width
        visible: root.elsewhere.length > 0
        spacing: Style.space(3)

        Text {
          text: "PLAYING ELSEWHERE"
          color: Qt.darker(popup.fg, 1.5)
          font.family: popup.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Repeater {
          model: root.elsewhere
          Item {
            required property var modelData
            width: parent.width
            implicitHeight: sessionText.implicitHeight + Style.space(6)

            readonly property bool isFollowed: String(modelData.player) === root.followedPlayer

            Text {
              id: sessionText
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              text: {
                var s = String(modelData.artist || "") + " — " + String(modelData.title || "")
                var meta = [String(modelData.player || "")]
                if (modelData.state === "paused") meta.push("paused")
                else if (modelData.minutesAgo > 0) meta.push(modelData.minutesAgo + "m ago")
                return s + "  ·  " + meta.join(" · ")
              }
              color: Qt.darker(popup.fg, parent.isFollowed ? 1.0 : 1.3)
              font.family: popup.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: parent.isFollowed
              opacity: sessionMouse.containsMouse || parent.isFollowed ? 1.0 : 0.85
              elide: Text.ElideRight

              Behavior on opacity { NumberAnimation { duration: 120 } }
            }

            MouseArea {
              id: sessionMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: parent.isFollowed ? root.unfollow() : root.follow(modelData.player)
            }
          }
        }

        Text {
          width: parent.width
          text: "Click a device to follow it in the bar."
          color: Qt.darker(popup.fg, 1.8)
          font.family: popup.fontFamily
          font.pixelSize: Style.font.caption
          visible: !root.following
        }
      }
    }
  }
}
