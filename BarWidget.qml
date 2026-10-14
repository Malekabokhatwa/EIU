import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// EIU - Egyptian Internet Usage.
// The heavy lifting (counting traffic, the Egypt check, provider detection,
// cycle math) lives in bin/eiu; this widget runs it every minute and draws
// what it reports.
BarWidget {
  id: root
  moduleName: "eiu"

  // ---- settings (shell.json entry; change with `omarchy bar set eiu <key> <value>`)
  readonly property string display: setting("display", "used")          // used | remaining | percent | icon
  readonly property bool showRing: setting("showRing", true) !== false
  readonly property int refreshSeconds: Math.max(15, parseInt(setting("refreshSeconds", 60), 10) || 60)

  readonly property string eiuPath: decodeURIComponent(Qt.resolvedUrl("bin/eiu").toString().replace(/^file:\/\//, ""))
  function eiu(args) { return ["python3", root.eiuPath].concat(args) }

  property var status: null
  property bool loaded: false
  readonly property bool enabledHere: !!status && status.enabled === true
  readonly property bool needsSetup: enabledHere && status.setup_done !== true
  readonly property int base: status ? status.unit_base : 1000
  readonly property real fraction: status && status.quota ? Math.min(1, status.used / status.quota) : 0

  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property color warnColor: Qt.tint(Color.accent, Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.55))
  readonly property color levelColor: {
    if (!status) return Color.accent
    if (status.level === "over" || status.level === "critical") return Color.urgent
    if (status.level === "warning") return warnColor
    return Color.accent
  }

  readonly property string barText: {
    if (!status) return ""
    if (needsSetup) return "Set up"
    if (display === "icon") return ""
    if (display === "percent" && status.quota) return Math.round(status.percent) + "%"
    if (display === "remaining" && status.quota) return Model.compactBytes(status.remaining, base) + " left"
    return Model.compactBytes(status.used, base)
  }

  readonly property string tooltip: {
    if (!status) return "EIU: starting…"
    if (needsSetup) return "EIU: click to set up your provider and plan"
    var s = status.provider_short + " · " + status.used_label
    if (status.quota) s += " of " + status.plan_label + " (" + Math.round(status.percent) + "%)"
    s += "\nRenews " + status.cycle.renews_label + " (" + Model.daysLabel(status.cycle.days_left) + ")"
    s += "\nToday " + status.today_label
    if (status.debug) s += "\n[debug mode]"
    return s
  }

  // ---- popup state
  property bool panelOpen: false
  property bool popoutSwitchClosing: false
  property bool setupView: false
  readonly property bool opened: panelOpen
  property int hoverDay: -1

  function open() { if (needsSetup) beginSetup(); panelOpen = true; refresh() }
  function close() { panelOpen = false; setupView = false }
  function toggle() { panelOpen ? close() : open() }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function") return root.bar.switchPanelFrom(root, direction)
    return false
  }

  // ---- talking to bin/eiu
  function refresh() {
    if (!collectProc.running) {
      collectProc.command = eiu(["collect", "--status"])
      collectProc.running = true
    }
  }

  function applyStatus(text) {
    try {
      var s = JSON.parse(String(text || "").trim())
      if (s && s.version) { root.status = s; root.loaded = true }
    } catch (e) {
      console.warn("eiu: could not read status: " + e)
    }
  }

  Process {
    id: collectProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
  }

  Process {
    id: configureProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.applyStatus(text); root.saving = false; root.setupView = false }
    }
  }

  Timer {
    interval: root.refreshSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- setup form state (filled from status when the form opens)
  property string formProvider: "etisalat"
  property string formPlan: "300"
  property int formCustomGb: 250
  property string formMode: "monthly"
  property int formDay: 15
  property string formAnchor: ""
  property bool formHomeOnly: true
  property bool formNotify: true
  property bool formDebug: false
  property bool saving: false

  readonly property var providerDefaults: ({
    "etisalat": { mode: "monthly", day: 15 },
    "we": { mode: "every30", day: 1 },
    "orange": { mode: "monthly", day: 1 },
    "vodafone": { mode: "monthly", day: 1 },
    "noor": { mode: "monthly", day: 1 },
    "other": { mode: "monthly", day: 1 }
  })

  function beginSetup() {
    var s = root.status || {}
    var detected = s.detected ? s.detected.provider : "other"
    formProvider = (s.provider_source === "manual" ? s.provider : detected) || "etisalat"
    var gb = s.plan_gb || 300
    formPlan = Model.isStandardPlan(gb) ? String(gb) : "custom"
    formCustomGb = gb
    var r = s.renewal || {}
    formMode = r.mode || providerDefaults[formProvider].mode
    formDay = r.day || providerDefaults[formProvider].day
    formAnchor = r.anchor || Qt.formatDate(new Date(), "yyyy-MM-dd")
    formHomeOnly = s.count !== "all"
    formDebug = !!s.debug
    formNotify = s.notify !== false
    setupView = true
  }

  function pickProvider(p) {
    formProvider = p
    var d = providerDefaults[p] || providerDefaults.other
    formMode = d.mode
    formDay = d.day
  }

  function saveSetup() {
    var patch = {
      "provider": formProvider,
      "plan": formPlan === "custom" ? String(formCustomGb) : formPlan,
      "renewal-mode": formMode,
      "renewal-day": String(formDay),
      "count": formHomeOnly ? "home" : "all",
      "notify": formNotify ? "on" : "off",
      "debug": formDebug ? "on" : "off"
    }
    if (formMode === "every30") patch["renewal-anchor"] = formAnchor
    if (formHomeOnly) patch["home-current"] = ""
    saving = true
    configureProc.command = eiu(["configure", JSON.stringify(patch)])
    configureProc.running = true
  }

  // ---- shell IPC: omarchy-shell eiu <method>
  IpcHandler {
    target: "eiu"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function setup(): void { root.panelOpen = true; root.beginSetup() }
    function status(): string { return JSON.stringify(root.status || {}) }
  }

  // ---- bar presence: invisible outside Egypt (unless debug mode is on)
  visible: enabledHere
  implicitWidth: enabledHere ? button.implicitWidth : 0
  implicitHeight: enabledHere ? button.implicitHeight : 0

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: root.enabledHere
    tooltipText: root.panelOpen ? "" : root.tooltip
    horizontalMargin: 7
    verticalPadding: 6
    fixedWidth: root.vertical ? -1 : (row.implicitWidth + button.scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? (col.implicitHeight + button.scaledVerticalPadding * 2) : -1

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) {
        var order = ["used", "remaining", "percent", "icon"]
        var next = order[(order.indexOf(root.display) + 1) % order.length]
        Quickshell.execDetached(["omarchy-bar", "set", "eiu", "display", next])
      } else root.toggle()
    }

    Row {
      id: row
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(6)

      Gauge {
        anchors.verticalCenter: parent.verticalCenter
        size: Style.font.body + Style.space(4)
      }

      Text {
        visible: text !== ""
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.barText
        color: root.needsSetup ? Color.accent : root.barForeground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    Column {
      id: col
      visible: root.vertical
      anchors.centerIn: parent
      spacing: Style.space(2)

      Gauge {
        anchors.horizontalCenter: parent.horizontalCenter
        size: Style.font.body + Style.space(4)
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: root.status && root.status.quota ? Math.round(root.status.percent) + "%" : ""
        color: root.barForeground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    // Open indicator, like the built-in pills.
    Rectangle {
      visible: root.panelOpen
      readonly property bool isVert: !!root.bar && root.bar.vertical
      color: root.levelColor
      anchors.bottom: isVert ? undefined : parent.bottom
      anchors.right: isVert ? parent.right : undefined
      anchors.horizontalCenter: isVert ? undefined : parent.horizontalCenter
      anchors.verticalCenter: isVert ? parent.verticalCenter : undefined
      width: isVert ? Style.space(2) : Style.space(18)
      height: isVert ? Style.space(18) : Style.space(2)
      radius: Style.cornerRadius > 0 ? 1 : 0
    }
  }

  // The bar icon: a quota ring (faint track, used share in the level colour)
  // around a two-tone pyramid, matching assets/icon.svg. Without a plan it's
  // just the pyramid.
  component Gauge: Item {
    id: gauge
    property real size: 18
    width: size
    height: size

    Canvas {
      id: ring
      anchors.fill: parent
      antialiasing: true
      readonly property bool hasRing: root.showRing && !!root.status && root.status.quota > 0
      property real frac: root.fraction
      property color track: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.22)
      property color fill: root.needsSetup ? Color.accent : root.levelColor
      property color face: hasRing ? fill : (root.needsSetup ? Color.accent : root.barForeground)
      onFracChanged: requestPaint()
      onFillChanged: requestPaint()
      onFaceChanged: requestPaint()
      onTrackChanged: requestPaint()
      onHasRingChanged: requestPaint()
      onWidthChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var w = width, h = height, cx = w / 2
        var lw = Math.max(1.6, w * 0.13)
        if (hasRing) {
          var r = w / 2 - lw / 2
          ctx.lineWidth = lw
          ctx.lineCap = "round"
          ctx.strokeStyle = track
          ctx.beginPath(); ctx.arc(cx, h / 2, r, 0, Math.PI * 2); ctx.stroke()
          if (frac > 0) {
            ctx.strokeStyle = fill
            ctx.beginPath()
            ctx.arc(cx, h / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0.02, frac))
            ctx.stroke()
          }
        }
        // The pyramid: lit face and shaded face, sitting on a base line.
        var ph = hasRing ? h * 0.40 : h * 0.66
        var pw = ph * 1.1
        var top = h / 2 - ph * 0.55, base = top + ph
        ctx.fillStyle = face
        ctx.beginPath(); ctx.moveTo(cx, top); ctx.lineTo(cx - pw / 2, base); ctx.lineTo(cx, base); ctx.closePath(); ctx.fill()
        ctx.globalAlpha = 0.55
        ctx.beginPath(); ctx.moveTo(cx, top); ctx.lineTo(cx + pw / 2, base); ctx.lineTo(cx, base); ctx.closePath(); ctx.fill()
        ctx.globalAlpha = 1
      }
    }
  }

  // Small label/value pair used in the stats row.
  component Stat: Column {
    property string title: ""
    property string value: ""
    property string sub: ""
    property color valueColor: Color.foreground
    spacing: Style.space(3)
    Text {
      text: parent.title
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
    Text {
      textFormat: Text.PlainText
      text: parent.value || "—"
      color: parent.valueColor
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }
    Text {
      visible: text !== ""
      textFormat: Text.PlainText
      text: parent.sub
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // Row with a label on the left and a control on the right (setup form).
  component FormRow: Item {
    property string title: ""
    property string hint: ""
    default property alias control: slot.data
    width: parent ? parent.width : 0
    height: Math.max(labels.implicitHeight, slot.childrenRect.height)
    Column {
      id: labels
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width * 0.5
      spacing: Style.space(2)
      Text {
        text: title
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
      Text {
        visible: hint !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: hint
        color: Qt.darker(Color.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
    Item {
      id: slot
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: childrenRect.width
      height: childrenRect.height
    }
  }

  // ---------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.panelOpen
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: providerDrop.popupOpen || planDrop.popupOpen || modeDrop.popupOpen || anchorField.activeFocus
      onCloseRequested: root.setupView && root.status && root.status.setup_done ? (root.setupView = false) : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onReturnRequested: if (root.setupView) root.saveSetup()

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_S && !root.setupView) { root.beginSetup(); event.accepted = true }
        else if (event.key === Qt.Key_R) { root.refresh(); event.accepted = true }
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroller.width
          spacing: Style.space(14)
          topPadding: Style.space(6)
          bottomPadding: Style.space(10)

          // ---- header
          Item {
            width: parent.width
            height: Math.max(headIcon.height, headText.implicitHeight)

            Rectangle {
              id: headIcon
              width: Style.space(40)
              height: width
              radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(8)
              color: Qt.rgba(root.levelColor.r, root.levelColor.g, root.levelColor.b, 0.16)
              Gauge {
                anchors.centerIn: parent
                size: Style.space(26)
              }
            }

            Column {
              id: headText
              anchors.left: headIcon.right
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: headIcon.verticalCenter
              spacing: Style.space(2)
              Text {
                text: root.setupView ? "Set up EIU" : "Internet usage"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: root.status ? (root.status.provider_name + "  ·  " + root.status.plan_label) : "Reading counters…"
                color: Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: headIcon.verticalCenter
              spacing: Style.space(6)

              Rectangle {
                visible: root.status && root.status.debug
                anchors.verticalCenter: parent.verticalCenter
                width: debugText.implicitWidth + Style.space(12)
                height: debugText.implicitHeight + Style.space(4)
                radius: height / 2
                color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.2)
                Text {
                  id: debugText
                  anchors.centerIn: parent
                  text: "DEBUG"
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Button {
                iconText: root.setupView ? "󰅖" : "󰒓"
                tooltipText: root.setupView ? "Back" : "Setup (S)"
                visible: !root.setupView || (root.status && root.status.setup_done)
                onClicked: root.setupView ? (root.setupView = false) : root.beginSetup()
              }
            }
          }

          // ================================================== dashboard
          Column {
            visible: !root.setupView
            width: parent.width
            spacing: Style.space(14)

            // Hero: big number + progress bar with a pace marker.
            Column {
              width: parent.width
              spacing: Style.space(8)

              Row {
                spacing: Style.space(8)
                Text {
                  id: heroNum
                  textFormat: Text.PlainText
                  text: root.status ? root.status.used_label : "—"
                  color: root.levelColor
                  font.family: Style.font.family
                  // Hero read-out, deliberately bigger than the type scale (like weather).
                  font.pixelSize: 44
                  font.bold: true
                }
                Text {
                  anchors.baseline: heroNum.baseline
                  textFormat: Text.PlainText
                  text: root.status && root.status.quota ? ("of " + root.status.plan_label + "  ·  " + Math.round(root.status.percent) + "%") : "used this cycle"
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.title
                }
              }

              Item {
                visible: !!root.status && root.status.quota > 0
                width: parent.width
                height: Style.space(10)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius > 0 ? height / 2 : 0
                  color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
                }
                Rectangle {
                  width: parent.width * root.fraction
                  height: parent.height
                  radius: Style.cornerRadius > 0 ? height / 2 : 0
                  color: root.levelColor
                  Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                }
                // Where usage "should" be if spread evenly over the cycle.
                Rectangle {
                  x: parent.width * Model.elapsedFraction(root.status) - width / 2
                  y: -Style.space(3)
                  width: Style.space(2)
                  height: parent.height + Style.space(6)
                  color: Color.foreground
                  opacity: 0.55
                }
              }

              Text {
                visible: !!root.status && root.status.quota > 0
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: {
                  if (!root.status) return ""
                  var s = root.status
                  if (s.level === "over") return "Quota used up. Speed is probably throttled until " + s.cycle.renews_label + "."
                  if (s.projected > s.quota) return "At this pace you'll reach about " + s.projected_label + ", over your plan before renewal."
                  return "On pace for about " + s.projected_label + " by renewal. The line marks an even pace."
                }
                color: root.status && root.status.projected > root.status.quota ? root.warnColor : Qt.darker(Color.foreground, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // Stats
            Row {
              width: parent.width
              spacing: Style.space(26)
              Stat {
                title: "RENEWS"
                value: root.status ? root.status.cycle.renews_label : ""
                sub: root.status ? Model.daysLabel(root.status.cycle.days_left) : ""
                valueColor: Color.accent
              }
              Stat {
                visible: !!root.status && root.status.quota > 0
                title: "LEFT"
                value: root.status ? root.status.remaining_label : ""
                sub: root.status && root.status.quota ? ("≈ " + root.status.daily_budget_label + " / day") : ""
              }
              Stat {
                title: "TODAY"
                value: root.status ? root.status.today_label : ""
                sub: root.status ? ("avg " + root.status.average_label) : ""
              }
            }

            PanelSeparator { foreground: Color.popups.border }

            // Daily chart: one bar per day of the cycle.
            Column {
              width: parent.width
              spacing: Style.space(6)

              Item {
                width: parent.width
                height: chartTitle.implicitHeight
                PanelSectionHeader {
                  id: chartTitle
                  text: "EACH DAY THIS CYCLE"
                  foreground: Color.foreground
                }
                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: chartTitle.verticalCenter
                  textFormat: Text.PlainText
                  text: {
                    var d = root.status ? root.status.daily : []
                    var i = root.hoverDay >= 0 ? root.hoverDay : d.findIndex(function(x) { return x.today })
                    if (i < 0 || !d[i]) return ""
                    var x = d[i]
                    if (x.future) return Model.shortDate(x.date) + "  ·  ahead"
                    if (!x.tracked) return Model.shortDate(x.date) + "  ·  before tracking"
                    return Model.shortDate(x.date) + "  ·  " + Model.formatBytes(x.total, root.base)
                      + "  (↓" + Model.formatBytes(x.rx, root.base) + " ↑" + Model.formatBytes(x.tx, root.base) + ")"
                  }
                  color: Qt.darker(Color.foreground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Item {
                id: chart
                width: parent.width
                height: Style.space(96)
                readonly property var days: root.status ? root.status.daily : []
                readonly property real peak: {
                  var m = 1
                  for (var i = 0; i < days.length; i++) m = Math.max(m, days[i].total)
                  return m
                }
                readonly property real budget: root.status && root.status.quota ? root.status.quota / root.status.cycle.length : 0

                Row {
                  anchors.bottom: parent.bottom
                  width: parent.width
                  height: parent.height
                  spacing: Style.space(2)

                  Repeater {
                    model: chart.days
                    Item {
                      required property var modelData
                      required property int index
                      width: (chart.width - Style.space(2) * (chart.days.length - 1)) / Math.max(1, chart.days.length)
                      height: chart.height

                      Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: modelData.future || !modelData.tracked
                          ? Style.space(2)
                          : Math.max(Style.space(2), parent.height * modelData.total / chart.peak)
                        radius: Style.cornerRadius > 0 ? Math.min(3, width / 2) : 0
                        color: modelData.today ? root.levelColor
                          : (chart.budget > 0 && modelData.total > chart.budget ? root.warnColor : Color.foreground)
                        opacity: modelData.future || !modelData.tracked ? 0.15
                          : (modelData.today || root.hoverDay === index ? 1 : 0.45)
                        Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: root.hoverDay = index
                        onExited: if (root.hoverDay === index) root.hoverDay = -1
                      }
                    }
                  }
                }

                // Even-split daily budget line, when it fits on the chart.
                Rectangle {
                  visible: chart.budget > 0 && chart.budget < chart.peak
                  width: parent.width
                  height: 1
                  y: parent.height - parent.height * chart.budget / chart.peak
                  color: Color.accent
                  opacity: 0.5
                }
              }

              Item {
                width: parent.width
                height: firstDay.implicitHeight
                Text {
                  id: firstDay
                  text: root.status ? Model.shortDate(root.status.cycle.start) : ""
                  color: Qt.darker(Color.foreground, 1.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.right: parent.right
                  text: root.status ? "renews " + Model.shortDate(root.status.cycle.renews) : ""
                  color: Qt.darker(Color.foreground, 1.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Footer: what's being counted, and caveats.
            Column {
              width: parent.width
              spacing: Style.space(4)
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: {
                  if (!root.status) return ""
                  var s = root.status
                  if (s.count === "all" || !s.home_networks.length) return "Counting every network this computer uses."
                  return "Counting only " + s.home_networks.join(", ") + "."
                }
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Text {
                visible: !!root.status && root.status.partial
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.status ? ("Tracking began " + Model.shortDate(root.status.tracking_since)
                  + ". To include earlier days, run: eiu adjust <figure from " + root.status.renewal.app + ">") : ""
                color: Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ================================================== setup
          Column {
            visible: root.setupView
            width: parent.width
            spacing: Style.space(14)

            // Detection card
            Rectangle {
              width: parent.width
              height: detCol.implicitHeight + Style.space(20)
              radius: Style.cornerRadius
              color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
              border.width: 1
              border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.35)

              Column {
                id: detCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(10)
                spacing: Style.space(3)
                Text {
                  textFormat: Text.PlainText
                  text: {
                    var d = root.status ? root.status.detected : null
                    if (!d || !d.confidence) return "󰀦  Couldn't recognise your provider. Pick it below."
                    return "󰄬  Detected " + d.name + "  (" + d.confidence + "% sure)"
                  }
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Repeater {
                  model: root.status && root.status.detected ? root.status.detected.evidence : []
                  Text {
                    required property var modelData
                    textFormat: Text.PlainText
                    text: "·  " + modelData
                    color: Qt.darker(Color.foreground, 1.3)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
                Text {
                  visible: !!root.status
                  textFormat: Text.PlainText
                  text: root.status ? ("Router: " + (root.status.detected.signals.router || "unknown")
                    + "  ·  " + (root.status.location.city || "") + " " + (root.status.location.country || "")) : ""
                  color: Qt.darker(Color.foreground, 1.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            FormRow {
              title: "Provider"
              Dropdown {
                id: providerDrop
                width: Style.space(220)
                showLabel: false
                options: root.status ? root.status.providers : []
                value: root.formProvider
                onChanged: function(v) { root.pickProvider(v) }
              }
            }

            FormRow {
              title: "Data plan"
              hint: "Your monthly quota"
              Dropdown {
                id: planDrop
                width: Style.space(220)
                showLabel: false
                options: Model.planOptions()
                value: root.formPlan
                onChanged: function(v) { root.formPlan = v }
              }
            }

            FormRow {
              visible: root.formPlan === "custom"
              title: "Custom plan (GB)"
              NumberField {
                from: 1
                to: 10000
                stepSize: 10
                value: root.formCustomGb
                onModified: function(v) { root.formCustomGb = v }
              }
            }

            FormRow {
              title: "Renews"
              hint: root.formMode === "every30" ? "30 days after each renewal (WE style)" : "Same day every month"
              Dropdown {
                id: modeDrop
                width: Style.space(220)
                showLabel: false
                options: [{ value: "monthly", label: "Monthly on a day" }, { value: "every30", label: "Every 30 days" }]
                value: root.formMode
                onChanged: function(v) { root.formMode = v }
              }
            }

            FormRow {
              visible: root.formMode === "monthly"
              title: "Renewal day"
              hint: root.formProvider === "etisalat" ? "e& renews on the 15th" : "Day of the month"
              NumberField {
                from: 1
                to: 31
                value: root.formDay
                onModified: function(v) { root.formDay = v }
              }
            }

            FormRow {
              visible: root.formMode === "every30"
              title: "Last renewal"
              hint: "YYYY-MM-DD"
              TextField {
                id: anchorField
                width: Style.space(140)
                text: root.formAnchor
                foreground: Color.foreground
                onTextChanged: root.formAnchor = text
              }
            }

            FormRow {
              title: "Home network only"
              hint: root.status && root.status.networks_now.length ? ("Count traffic on " + root.status.networks_now.join(", ") + ", not cafés or hotspots") : "Count only your home network"
              ToggleSwitch {
                checked: root.formHomeOnly
                onToggled: root.formHomeOnly = !root.formHomeOnly
              }
            }

            FormRow {
              title: "Quota alerts"
              hint: "Notify at 75%, 90% and 100%"
              ToggleSwitch {
                checked: root.formNotify
                onToggled: root.formNotify = !root.formNotify
              }
            }

            FormRow {
              title: "Debug mode"
              hint: "Run outside Egypt (for testing)"
              ToggleSwitch {
                checked: root.formDebug
                onToggled: root.formDebug = !root.formDebug
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.status ? root.status.renewal.note : ""
              color: Qt.darker(Color.foreground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              Button {
                Layout.fillWidth: true
                bordered: true
                visible: !!root.status && root.status.setup_done
                text: "Cancel"
                onClicked: root.setupView = false
              }
              Button {
                Layout.fillWidth: true
                bordered: true
                active: true
                iconText: root.saving ? "󰦖" : "󰄬"
                iconSpinning: root.saving
                text: root.saving ? "Saving…" : "Save"
                onClicked: if (!root.saving) root.saveSetup()
              }
            }
          }
        }
      }
    }
  }
}
