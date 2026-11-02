/**
 * DSM 7.0 / 7.1 desktop window for synoterm — ExtJS.
 *
 * DSM's window manager is ExtJS on these versions. Registering `type: "app"`
 * with an `appWindow` class (ui/config) makes DSM open a real desktop window —
 * title bar, minimise/maximise, resize, taskbar entry — instead of a browser
 * popup, which is what `type: "url"` produces.
 *
 * The window body is an iframe pointing at the UI that DSM itself serves from
 * this package (/webman/3rdparty/synoterm/web/). Keeping the terminal in an
 * iframe is deliberate:
 *
 *   - isolation: xterm.js measures its own font metrics and ships its own CSS;
 *     DSM's ExtJS desktop stylesheet and global font rules cannot disturb it,
 *     and a rendering problem cannot wedge the desktop;
 *   - lifecycle: closing the window destroys the frame, so the WebSocket, the
 *     PTY and every timer die with it (no leaks in the desktop page);
 *   - multi-instance: `allowMultiInstance` gives each window its own JS context,
 *     so the terminal UI needs no per-window plumbing.
 *
 * Embedding xterm.js directly into an ExtJS panel is possible (the panel would
 * host `<div class="synoterm-host">` and our bundle would mount into it via
 * `afterrender`), at the cost of scoping xterm's CSS under DSM's global rules,
 * refactoring the UI from module singletons into instances, and disposing the
 * terminal on window destroy. The iframe costs nothing measurable: keystrokes
 * and output cross the boundary as the same WebSocket frames.
 */
Ext.ns("SYNO.SDS.App.Synoterm");

SYNO.SDS.App.Synoterm = Ext.extend(SYNO.SDS.AppWindow, {
  constructor: function () {
    this.frameId = Ext.id(null, "synoterm-frame-");
    this.boundRaise = this.raiseWindow.createDelegate(this);

    SYNO.SDS.App.Synoterm.superclass.constructor.call(this, {
      width: 1000,
      height: 650,
      minWidth: 480,
      minHeight: 320,
      maximizable: true,
      resizable: true,
      layout: "fit",
      title: "Terminal",
      iconCls: "synoterm-window-icon",
      items: [
        {
          xtype: "panel",
          border: false,
          layout: "fit",
          // Absolute path from the web root: DSM resolves relative paths
          // against "/", not "/webman/".
          html:
            '<iframe id="' +
            this.frameId +
            '" src="/webman/3rdparty/synoterm/web/index.html" ' +
            'style="display:block;width:100%;height:100%;border:0;background:#10161d" ' +
            'allow="clipboard-read; clipboard-write"></iframe>',
        },
      ],
      listeners: {
        show: this.onWindowShow,
        activate: this.onWindowActivate,
        destroy: this.onWindowDestroy,
        scope: this,
      },
    });
  },

  /** Clicks inside an iframe do not reach the parent: raise ourselves. */
  attachFrameListeners: function () {
    var frame = document.getElementById(this.frameId);
    if (!frame) {
      return;
    }
    frame.onmousedown = this.boundRaise;
    frame.onclick = this.boundRaise;

    // Same origin, so the inner document can be reached as well. This makes the
    // window behave like any other DSM window when the user clicks the terminal.
    try {
      var doc = frame.contentWindow && frame.contentWindow.document;
      if (doc) {
        doc.onmousedown = this.boundRaise;
        if (doc.body) doc.body.onmousedown = this.boundRaise;
      }
    } catch (e) {
      /* cross-origin frame: nothing to do */
    }
  },

  raiseWindow: function () {
    this.toFront();
    this.setActive();
  },

  onWindowShow: function () {
    this.attachFrameListeners();
    var frame = document.getElementById(this.frameId);
    if (frame) frame.focus();
  },

  onWindowActivate: function () {
    // The frame reloads if the window is reopened; re-bind after every load.
    var frame = document.getElementById(this.frameId);
    if (frame) {
      frame.onload = this.attachFrameListeners.createDelegate(this);
      this.attachFrameListeners();
      try {
        if (frame.contentWindow) frame.contentWindow.focus();
      } catch (e) {
        /* ignore */
      }
    }
  },

  onWindowDestroy: function () {
    // Removing the iframe is what stops the terminal: the frame's JS context
    // goes away, closing its WebSocket and freeing the PTY.
    var frame = document.getElementById(this.frameId);
    if (frame && frame.parentNode) frame.parentNode.removeChild(frame);
  },
});

SYNO.SDS.App.Synoterm.Instance = Ext.extend(SYNO.SDS.AppInstance, {
  appWindowName: "SYNO.SDS.App.Synoterm",
});
