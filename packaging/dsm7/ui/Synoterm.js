/**
 * DSM desktop integration for synoterm.
 *
 * DSM loads this file as the application class named in ui/config. The heavy
 * lifting (xterm.js, tabs, WebSocket) lives inside an iframe so that DSM's
 * Vue/ExtJS globals, stylesheets and upgrade leftovers can never interfere
 * with the terminal rendering.
 *
 * Two things are injected into the iframe URL:
 *   ws=<path>       the nginx proxy mount point (see packaging/dsm7/nginx)
 *   SynoToken=<...> DSM's CSRF token, appended by DSM to this script's own
 *                   src; forwarded so the backend can authenticate the
 *                   desktop session through authenticate.cgi.
 */
(function registerSynotermApplication() {
  "use strict";

  var SCRIPT_MARKER = "Synoterm.js";

  function synoToken() {
    var scripts = document.getElementsByTagName("script");
    for (var i = scripts.length - 1; i >= 0; i -= 1) {
      var src = scripts[i].getAttribute("src") || "";
      if (src.indexOf(SCRIPT_MARKER) === -1) continue;
      try {
        return new URL(src, window.location.href).searchParams.get("SynoToken") || "";
      } catch (error) {
        return "";
      }
    }
    return "";
  }

  function frameUrl() {
    var params = new URLSearchParams();
    params.set("ws", "/synoterm/ws");
    var token = synoToken();
    if (token) params.set("SynoToken", token);
    return "webman/3rdparty/synoterm/web/index.html?" + params.toString();
  }

  SYNO.namespace("SYNO.SDS.App.Synoterm");

  SYNO.SDS.App.Synoterm.Instance = Vue.extend({
    data: function data() {
      return { frameSrc: frameUrl() };
    },
    template: [
      '<v-app-instance class-name="SYNO.SDS.App.Synoterm.Instance">',
      '  <v-app-window width="1040" height="680" ref="appWindow" :resizable="true"',
      '                syno-id="SYNO.SDS.App.Synoterm.Window">',
      '    <iframe class="synoterm-frame" :src="frameSrc"',
      '            style="width:100%;height:100%;border:0;display:block"',
      '            referrerpolicy="same-origin"></iframe>',
      '  </v-app-window>',
      '</v-app-instance>',
    ].join(""),
  });
})();
