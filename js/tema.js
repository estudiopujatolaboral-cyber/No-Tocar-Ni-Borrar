// Modo claro / oscuro del sitio.
// Se carga en el <head> de todas las páginas para aplicar el tema guardado antes de dibujar la página
// (así no hay un "parpadeo" blanco). Agrega el botón en la barra superior y recuerda la elección.
(function () {
  var CLAVE = 'tema';
  var raiz = document.documentElement;

  function guardado() {
    try { return localStorage.getItem(CLAVE); } catch (e) { return null; }
  }
  function aplicar(tema) {
    if (tema === 'dark') raiz.setAttribute('data-theme', 'dark');
    else raiz.removeAttribute('data-theme');
  }
  function oscuro() { return raiz.getAttribute('data-theme') === 'dark'; }

  // Por defecto el sitio se ve claro; solo cambia si la persona eligió el modo oscuro.
  aplicar(guardado());

  // Gráficos (Chart.js): textos y líneas de grilla legibles en cada tema.
  function ajustarGraficos() {
    if (!window.Chart || !window.Chart.instances) return;
    var texto = oscuro() ? '#cfccbd' : '#666';
    var grilla = oscuro() ? 'rgba(255,255,255,.12)' : 'rgba(0,0,0,.1)';
    window.Chart.defaults.color = texto;
    window.Chart.defaults.borderColor = grilla;
    Object.keys(window.Chart.instances).forEach(function (k) {
      var g = window.Chart.instances[k], o = g.options;
      Object.keys(o.scales || {}).forEach(function (eje) {
        var s = o.scales[eje];
        if (s.ticks) s.ticks.color = texto;
        if (s.grid) s.grid.color = grilla;
        if (s.title) s.title.color = texto;
      });
      if (o.plugins && o.plugins.legend && o.plugins.legend.labels) o.plugins.legend.labels.color = texto;
      if (o.plugins && o.plugins.title) o.plugins.title.color = texto;
      g.update('none');
    });
  }

  function crearBoton() {
    var lugar = document.querySelector('.topbar-icons');
    if (!lugar || lugar.querySelector('.tema-toggle')) return;
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'tema-toggle';
    b.innerHTML =
      '<svg class="icono-luna" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>' +
      '<svg class="icono-sol" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4.5"/><path d="M12 2v2.5M12 19.5V22M2 12h2.5M19.5 12H22M4.9 4.9l1.8 1.8M17.3 17.3l1.8 1.8M4.9 19.1l1.8-1.8M17.3 6.7l1.8-1.8"/></svg>';
    function etiquetar() {
      var t = oscuro() ? 'Cambiar a fondo claro' : 'Cambiar a fondo oscuro';
      b.setAttribute('aria-label', t);
      b.title = t;
      b.setAttribute('aria-pressed', String(oscuro()));
    }
    etiquetar();
    b.addEventListener('click', function () {
      var nuevo = oscuro() ? 'light' : 'dark';
      aplicar(nuevo);
      try { localStorage.setItem(CLAVE, nuevo); } catch (e) { /* sin almacenamiento: vale solo para esta página */ }
      etiquetar();
      ajustarGraficos();
    });
    lugar.insertBefore(b, lugar.firstChild);
  }

  function alCargar() { crearBoton(); ajustarGraficos(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', alCargar);
  else alCargar();
  // Los gráficos se arman después de cargar los datos: se vuelven a ajustar cuando termina la carga.
  window.addEventListener('load', ajustarGraficos);
})();
