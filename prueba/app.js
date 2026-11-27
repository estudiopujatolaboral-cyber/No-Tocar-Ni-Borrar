/* Facturá Fácil — versión para navegador (prueba).
   Basada en facturafacil/web/app/app.js: mismas llamadas a la API y mismas reglas.
   Diferencias:
   - diseño de página web (sin el formato de celular) y navegación con el botón Atrás del navegador;
   - sin las secciones "Recomendar" y "El estudio";
   - la API la responde simulador.js (no hay servidor ni conexión con ARCA);
   - Factura A, B y C: cada cliente ve las que le corresponden según su condición frente al IVA
     (Responsable Inscripto: A y B; Monotributista o Exento: C). La app real por ahora emite solo C;
   - los clientes de ejemplo ya tienen su contraseña: entran directo, sin el paso de cambiar la clave inicial.
     Si alguna vez la API pide cambiarla (debe_cambiar_password), se muestra la ventana para hacerlo. */
const $ = s => document.querySelector(s);
const $$ = s => document.querySelectorAll(s);
const fmt = n => '$ ' + Number(n).toLocaleString('es-AR', {minimumFractionDigits: 0, maximumFractionDigits: 2});
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fechaAR = f => f ? f.split('-').reverse().join('/') : '';
const fmtCuit = c => (c && c.length === 11) ? `${c.slice(0, 2)}-${c.slice(2, 10)}-${c.slice(10)}` : (c || '');
const pctTxt = p => String(p).replace('.', ',') + '%';
const r2 = x => Math.round(x * 100) / 100;
const HINTS = {
  'Contado': 'Efectivo.',
  'Transferencia Bancaria': 'Transferencia, DEBIN o pago con CBU/CVU.',
  'Otros medios de pago electrónico': 'QR, Mercado Pago, Ualá, billeteras virtuales, tarjetas prepagas o eCheq.',
  'Tiquet': 'Tickets o vales de alimentación.',
};
const CONCEPTOS_RAPIDOS = ['Honorarios profesionales', 'Servicios prestados', 'Venta de productos'];
const ESTADOS = {autorizada: 'Autorizada', pendiente: 'Pendiente', rechazada: 'Rechazada'};
const COND_CORTA = {'IVA Responsable Inscripto': 'Responsable Inscripto', 'Responsable Monotributo': 'Monotributo', 'IVA Sujeto Exento': 'IVA Exento'};
const TIPO_HINT = {
  A: 'Para clientes Responsables Inscriptos o Monotributistas. Cargás el importe sin IVA y el IVA se suma aparte.',
  B: 'Para consumidores finales, exentos y no categorizados. Cargás el precio final, con el IVA incluido. ¿Tu cliente es Responsable Inscripto o Monotributista? Elegí Factura A.',
};
const letrasTxt = (tipos, une) => 'Factura ' + tipos.map(t => t.letra).join(une);

let token = null, me = null, params = null, ultimaFactura = null, receptores = [], facturasCache = [];
let recienEmitida = false;
try { token = localStorage.getItem('ff_token'); } catch (e) {}

async function api(path, opts = {}) {
  const r = await Simulador.fetch('/api' + path, { // en la app real: fetch('/api' + path, ...)
    ...opts,
    headers: {'Content-Type': 'application/json', ...(token ? {Authorization: 'Bearer ' + token} : {}), ...(opts.headers || {})},
  });
  if (r.status === 401 && path !== '/auth/login') { salir(false); throw new Error('Tu sesión venció. Ingresá de nuevo.'); }
  if (!r.ok) {
    let msg = 'Error ' + r.status;
    try { const j = await r.json(); msg = typeof j.detail === 'string' ? j.detail : (j.detail?.[0]?.msg || msg); } catch (e) {}
    throw new Error(msg);
  }
  return opts.raw ? r : r.json();
}

function toast(t) { const e = $('#toast'); e.textContent = t; e.style.display = 'block'; clearTimeout(e._t); e._t = setTimeout(() => e.style.display = 'none', 3500); }

/* ---------- Ventanas emergentes ---------- */
function abrir(id) { $('#' + id).classList.add('on'); }
function cerrar(s) { if (s && !s.dataset.forzado) s.classList.remove('on'); } // la de "cambiar clave" obligatoria no se cierra
function cerrarSheets() { $$('.sheet').forEach(cerrar); }

document.addEventListener('click', e => {
  const g = e.target.closest('[data-go]'); if (g) { e.preventDefault(); go(g.dataset.go); return; }
  const sh = e.target.closest('[data-sheet]');
  if (sh) { e.preventDefault(); if (!sh.closest('.sheet')) cerrarSheets(); abrir(sh.dataset.sheet); return; } // desde otra ventana, se apila
  const c = e.target.closest('[data-close]'); if (c) { cerrar(c.closest('.sheet')); return; }
  if (e.target.classList.contains('sheet')) { cerrar(e.target); return; } // clic en el fondo oscuro
  const r = e.target.closest('[data-id]'); if (r) abrirFactura(r.dataset.id);
});
document.addEventListener('keydown', e => {
  if (e.key !== 'Escape') return;
  const abiertas = $$('.sheet.on'); cerrar(abiertas[abiertas.length - 1]);
});

/* ---------- Navegación (funciona el botón Atrás del navegador) ---------- */
function go(ruta) { if (location.hash.slice(1) === ruta) render(); else location.hash = ruta; }
window.addEventListener('hashchange', render);

function mostrar(vista) {
  $$('.vista').forEach(s => { s.hidden = s.id !== 'v-' + vista; });
  const marcada = vista === 'factura' ? 'historial' : vista;
  $$('[data-nav]').forEach(a => a.classList.toggle('on', a.dataset.nav === marcada));
  window.scrollTo(0, 0);
}

function render() {
  const [vista, arg] = location.hash.slice(1).split('/');
  cerrarSheets();
  $('#nav').hidden = !me;
  $('#usuario').hidden = !me;
  if (!me) return mostrar('login');
  if (vista === 'nueva') { mostrar('nueva'); prepararNueva(); }
  else if (vista === 'historial') { mostrar('historial'); cargarHistorial(); }
  else if (vista === 'factura') verFactura(arg);
  else { // inicio (cualquier otra dirección, por ejemplo una vieja #estudio, también lleva al inicio)
    if (vista !== 'home') history.replaceState(null, '', '#home');
    mostrar('home'); cargarHome();
  }
}

/* ---------- Sesión ---------- */
$('#fLogin').addEventListener('submit', async e => {
  e.preventDefault();
  try {
    const r = await api('/auth/login', {method: 'POST', body: JSON.stringify({usuario: $('#lCuit').value, password: $('#lPw').value})});
    if (r.rol !== 'cliente') { toast('Este acceso es para clientes. El estudio usa el panel /admin.'); return; }
    token = r.token; try { localStorage.setItem('ff_token', token); } catch (e) {}
    $('#lPw').value = '';
    await entrar();
  } catch (err) { toast(err.message); }
});
// Cuentas de ejemplo: un toque y entra
$$('.demo-cuenta').forEach(b => b.onclick = () => {
  $('#lCuit').value = b.dataset.cuit; $('#lPw').value = 'inicio123';
  $('#fLogin button[type=submit]').click();
});

async function entrar() {
  me = await api('/me');
  pintarUsuario();
  const ruta = location.hash.slice(1);
  if (!ruta || ruta === 'login') go('home'); else render();
  if (me.debe_cambiar_password || !me.acepto_terminos) abrirClave(true);
}

function pintarUsuario() {
  $('#uNombre').textContent = me.nombre;
  $('#uCuit').textContent = 'CUIT ' + fmtCuit(me.cuit);
  $('#cuentaTxt').innerHTML = `<b style="color:var(--ink)">${esc(me.nombre)}</b><br>CUIT ${esc(fmtCuit(me.cuit))} · Punto de venta ${me.punto_venta}`
    + `<br>${esc(me.condicion_iva)} · Emitís ${esc(letrasTxt(me.tipos_cbte, ' y '))}`;
}

function abrirClave(obligatoria) {
  const s = $('#clave');
  if (obligatoria) s.dataset.forzado = '1'; else delete s.dataset.forzado;
  $('#claveTxt').textContent = obligatoria
    ? 'Es tu primer ingreso. Cambiá la contraseña que te dio el estudio.'
    : 'Ingresá tu contraseña actual y elegí una nueva.';
  $('#terminosBox').hidden = !!(me && me.acepto_terminos);
  $('#claveCancelar').hidden = obligatoria;
  cerrarSheets(); abrir('clave'); $('#cAct').focus();
}

$('#fClave').addEventListener('submit', async e => {
  e.preventDefault();
  try {
    await api('/auth/cambiar-password', {method: 'POST', body: JSON.stringify({actual: $('#cAct').value, nueva: $('#cNue').value, acepto_terminos: $('#cTer').checked})});
    $('#cAct').value = $('#cNue').value = '';
    const s = $('#clave'); delete s.dataset.forzado; cerrar(s);
    toast('Contraseña actualizada');
    await entrar();
  } catch (err) { toast(err.message); }
});

function salir(aviso = true) {
  token = null; me = null; try { localStorage.removeItem('ff_token'); } catch (e) {}
  delete $('#clave').dataset.forzado;
  cerrarSheets(); go('login'); if (aviso) toast('Sesión cerrada');
}
$('#btnSalir').onclick = () => salir();
$('#btnCambiarClave').onclick = () => abrirClave(false);
$('#btnReiniciar').onclick = () => {
  if (!confirm('Se borran las facturas que emitiste y vuelven los datos de ejemplo. ¿Seguimos?')) return;
  Simulador.reiniciar(); salir(false); toast('Datos de prueba reiniciados');
};

/* ---------- Inicio ---------- */
const fila = f => {
  const cls = f.estado === 'autorizada' ? '' : f.estado === 'pendiente' ? 'pend' : 'rech';
  const txt = f.estado === 'autorizada' ? f.letra : f.estado === 'pendiente' ? '…' : '✕';
  const d = f.fecha.split('-').reverse().slice(0, 2).join('/');
  return `<div class="row" data-id="${f.id}"><div class="ic ${cls}">${txt}</div><div class="t"><b>${esc(f.receptor)}</b><small>${d} · N° ${f.numero} · ${esc(f.detalle)}${f.estado !== 'autorizada' ? ' · ' + f.estado : ''}</small></div><div class="m">${fmt(f.importe_total)}</div></div>`;
};
async function cargarHome() {
  try {
    me = await api('/me');
    pintarUsuario();
    $('#hNombre').textContent = me.nombre;
    $('#hBadge').textContent = (COND_CORTA[me.condicion_iva] || me.condicion_iva) + (me.categoria ? ' · Categoría ' + me.categoria : '')
      + ' · Emitís ' + letrasTxt(me.tipos_cbte, ' y ');
    $('#bigSub').textContent = letrasTxt(me.tipos_cbte, ' o ') + ' en 3 pasos';
    pintarMedidor();
    facturasCache = await api('/facturas?limite=100');
    $('#ultimas').innerHTML = facturasCache.slice(0, 5).map(fila).join('') || '<div class="vacio">Todavía no emitiste facturas</div>';
  } catch (err) { toast(err.message); }
}
function pintarMedidor() {
  const b = $('#barra'), av = $('#aviso');
  av.hidden = true; $('#barWrap').hidden = true; b.style.width = '0';
  if (me.tope_anual > 0) { // Monotributo: cuánto falta para el tope de la categoría
    $('#meterLbl').textContent = 'Facturado últimos 12 meses';
    $('#fact12').textContent = fmt(me.facturado_12m);
    $('#barWrap').hidden = false;
    const pct = Math.min(100, me.facturado_12m / me.tope_anual * 100);
    b.className = pct >= 90 ? 'tope' : pct >= 75 ? 'alto' : '';
    setTimeout(() => b.style.width = pct + '%', 100);
    $('#meterTxt').innerHTML = me.facturado_12m < me.tope_anual
      ? `Te quedan <b>${fmt(me.tope_anual - me.facturado_12m)}</b> antes del tope de tu categoría (${pct.toFixed(0)}%).`
      : `<b style="color:var(--bad)">Superaste el tope de tu categoría.</b> Consultá al estudio.`;
    av.hidden = pct < 80;
    av.textContent = 'Estás cerca del tope de tu categoría. El estudio te va a contactar por la recategorización.';
  } else if (me.condicion_iva === 'IVA Responsable Inscripto') { // Responsable Inscripto: lo del mes y su IVA
    $('#meterLbl').textContent = 'Facturado este mes (sin IVA)';
    $('#fact12').textContent = fmt(me.facturado_mes_neto);
    $('#meterTxt').innerHTML = `IVA débito fiscal del mes: <b>${fmt(me.iva_debito_mes)}</b>. El estudio lo usa para tu declaración de IVA.`;
  } else {
    $('#meterLbl').textContent = 'Facturado últimos 12 meses';
    $('#fact12').textContent = fmt(me.facturado_12m);
    $('#meterTxt').textContent = me.condicion_iva === 'Responsable Monotributo'
      ? 'El estudio todavía no cargó el tope de tu categoría.'
      : 'Como sujeto exento, tus facturas C no llevan IVA.';
  }
}

/* ---------- Mis facturas ---------- */
const filaTabla = f => `<tr data-id="${f.id}"><td>${fechaAR(f.fecha)}</td><td>${f.letra} ${f.numero}</td><td>${esc(f.receptor)}</td>`
  + `<td class="col-detalle">${esc(f.detalle)}</td><td><span class="estado ${f.estado}">${ESTADOS[f.estado] || esc(f.estado)}</span></td><td class="num">${fmt(f.importe_total)}</td></tr>`;
async function cargarHistorial() {
  try { facturasCache = await api('/facturas?limite=500'); } catch (err) { toast(err.message); }
  $('#todas').innerHTML = facturasCache.map(filaTabla).join('') || '<tr class="vacio"><td colspan="6">Todavía no emitiste facturas</td></tr>';
  const total = facturasCache.filter(f => f.estado === 'autorizada').reduce((s, f) => s + f.importe_total, 0), n = facturasCache.length;
  $('#tResumen').textContent = n ? `${n} ${n === 1 ? 'factura' : 'facturas'} · ${fmt(total)} facturado` : '';
}
function abrirFactura(id) {
  const f = facturasCache.find(x => String(x.id) === String(id));
  if (!f) return;
  if (f.estado === 'autorizada') go('factura/' + f.id);
  else toast(f.estado === 'pendiente' ? 'Pendiente: el estudio la está verificando con ARCA' : 'Rechazada: ' + (f.observaciones || ''));
}

/* ---------- Nueva factura ---------- */
let modo = 'cf', tipo = null; // tipo = código de ARCA del comprobante elegido (1 = A, 6 = B, 11 = C)
const letra = () => (me.tipos_cbte.find(t => t.id === tipo) || {letra: 'C'}).letra;

function ponerModo(v) {
  modo = v;
  $$('#segCli button').forEach(x => x.classList.toggle('on', x.dataset.v === v));
  $('#docBox').hidden = modo !== 'doc';
}
$$('#segCli button').forEach(b => b.onclick = () => ponerModo(b.dataset.v));

// Al elegir la letra se acomoda el formulario: a quién se le puede facturar y cómo se carga el importe
function aplicarTipo(id) {
  tipo = id;
  const L = letra(), esA = L === 'A';
  $$('#segTipo button').forEach(b => b.classList.toggle('on', +b.dataset.t === id));
  $('#nLetra').textContent = L;
  $('#tipoHint').textContent = L !== 'C' ? TIPO_HINT[L]
    : me.condicion_iva === 'IVA Sujeto Exento' ? 'Como sujeto exento emitís siempre Factura C, sin IVA.'
    : 'Como Monotributista emitís siempre Factura C, sin IVA.';
  // La Factura A siempre va con el CUIT del cliente
  $('#lblCli').hidden = $('#segCli').hidden = esA;
  if (esA) { ponerModo('doc'); $('#docTipo').value = '80'; }
  $('#docTipo').disabled = esA;
  // Condiciones frente al IVA del cliente que admite esta letra
  const permitidas = params.condiciones_por_letra[L], actual = +$('#condIva').value;
  $('#condIva').innerHTML = params.condiciones_iva_receptor.filter(c => permitidas.includes(c.id))
    .map(c => `<option value="${c.id}">${esc(c.nombre)}</option>`).join('');
  $('#condIva').value = String(permitidas.includes(actual) ? actual : L === 'B' ? 5 : 1);
  // Importe: en la A sin IVA, en la B con IVA incluido, en la C sin IVA
  $('#lblImporte').textContent = esA ? 'Importe sin IVA' : L === 'B' ? 'Precio final (IVA incluido)' : 'Importe';
  $('#alicBox').hidden = L === 'C';
  $('#filaImp').classList.toggle('sin-iva', L === 'C');
  calcular();
}

// Muestra cómo queda el total con el IVA (A y B)
function calcular() {
  const L = letra(), v = parseFloat(($('#importe').value || '0').replace(',', '.')) || 0, c = $('#calc');
  if (L === 'C' || !v) { c.hidden = true; return; }
  const a = params.alicuotas_iva.find(x => x.id === +$('#alicuota').value), p = a.pct / 100;
  if (L === 'A') {
    const neto = r2(v), iva = r2(neto * p);
    c.innerHTML = `Sin IVA ${fmt(neto)} + IVA ${pctTxt(a.pct)} ${fmt(iva)} = <b>Total ${fmt(r2(neto + iva))}</b>`;
  } else {
    const total = r2(v), neto = r2(total / (1 + p));
    c.innerHTML = `<b>Total ${fmt(total)}</b> · incluye IVA ${pctTxt(a.pct)} de ${fmt(r2(total - neto))}`;
  }
  c.hidden = false;
}

$('#conceptos').innerHTML = CONCEPTOS_RAPIDOS.map(n => `<span class="chip">${n}</span>`).join('');
$$('#conceptos .chip').forEach(c => c.onclick = () => $('#detalle').value = c.textContent);
$('#pago').addEventListener('change', () => $('#pagoHint').textContent = HINTS[$('#pago').value] || '');
$('#docTipo').addEventListener('change', () => { if ($('#docTipo').value === '96') $('#condIva').value = '5'; });
$('#importe').addEventListener('input', e => { e.target.value = e.target.value.replace(/[^\d,]/g, '').replace(/,(?=.*,)/g, ''); calcular(); });
$('#alicuota').addEventListener('change', calcular);

async function prepararNueva() {
  try {
    params = params || await api('/parametros');
    if (!$('#pago').options.length) {
      $('#pago').innerHTML = params.condiciones_venta.map(c => `<option>${esc(c)}</option>`).join('');
      $('#alicuota').innerHTML = params.alicuotas_iva.map(a => `<option value="${a.id}">${pctTxt(a.pct)}</option>`).join('');
      $('#pagoHint').textContent = HINTS[$('#pago').value] || '';
    }
    // Las letras que puede emitir este cliente (Responsable Inscripto: A y B; Monotributo o Exento: C)
    $('#segTipo').innerHTML = me.tipos_cbte.map(t => `<button type="button" data-t="${t.id}">${esc(t.nombre)}</button>`).join('');
    $('#segTipo').classList.toggle('unico', me.tipos_cbte.length === 1);
    $$('#segTipo button').forEach(b => b.onclick = () => aplicarTipo(+b.dataset.t));
    const sigue = me.tipos_cbte.some(t => t.id === tipo);
    aplicarTipo(sigue ? tipo : (me.tipos_cbte.find(t => t.letra === 'B') || me.tipos_cbte[0]).id);

    receptores = await api('/receptores');
    $('#frecuentes').innerHTML = receptores.slice(0, 8).map(r => `<span class="chip" data-r="${r.id}">${esc(r.nombre)}</span>`).join('');
    $$('#frecuentes .chip').forEach(c => c.onclick = () => {
      const r = receptores.find(x => x.id == c.dataset.r);
      if (me.tipos_cbte.length > 1) { // Responsable Inscripto: la letra la define el cliente
        const L = params.condiciones_por_letra.A.includes(r.condicion_iva_receptor_id) ? 'A' : 'B';
        const t = me.tipos_cbte.find(x => x.letra === L);
        if (t && t.id !== tipo) { aplicarTipo(t.id); toast(`A ${r.nombre} le corresponde Factura ${L}`); }
      }
      ponerModo('doc');
      $$('#frecuentes .chip').forEach(x => x.classList.toggle('on', x === c));
      $('#docTipo').value = r.doc_tipo; $('#docNro').value = r.doc_nro; $('#recNombre').value = r.nombre; $('#condIva').value = r.condicion_iva_receptor_id;
    });
    $('#detalle').focus();
  } catch (err) { toast(err.message); }
}

$('#btnEmitir').onclick = async () => {
  const importe = parseFloat(($('#importe').value || '0').replace(',', '.'));
  if (!importe) return toast('Ingresá un importe');
  if (!$('#detalle').value.trim()) return toast('Completá el concepto');
  const L = letra();
  const body = {tipo_cbte: tipo, detalle: $('#detalle').value.trim(), condicion_venta: $('#pago').value};
  body[L === 'A' ? 'importe_neto' : 'importe_total'] = importe;
  if (L !== 'C') body.alicuota_id = +$('#alicuota').value;
  if (modo === 'doc') {
    Object.assign(body, {doc_tipo: +$('#docTipo').value, doc_nro: $('#docNro').value.replace(/\D/g, ''),
      receptor_nombre: $('#recNombre').value.trim(), condicion_iva_receptor_id: +$('#condIva').value});
    if (!body.doc_nro || !body.receptor_nombre) return toast('Completá el documento y el nombre del cliente');
  }
  const Ld = $('#load'); Ld.style.display = 'flex'; $('#loadTxt').textContent = 'Conectando con ARCA…';
  const t = setTimeout(() => $('#loadTxt').textContent = 'Obteniendo CAE…', 900);
  $('#btnEmitir').disabled = true;
  try {
    const f = await api('/facturas', {method: 'POST', body: JSON.stringify(body)});
    mostrarFactura(f);
    $('#importe').value = ''; $('#docNro').value = ''; $('#recNombre').value = ''; calcular();
    $$('#frecuentes .chip').forEach(x => x.classList.remove('on'));
    recienEmitida = true;
    go('factura/' + f.id);
  } catch (err) { toast(err.message); }
  finally { clearTimeout(t); Ld.style.display = 'none'; $('#btnEmitir').disabled = false; }
};

/* ---------- Ver factura ---------- */
async function verFactura(id) {
  let f = ultimaFactura && String(ultimaFactura.id) === id ? ultimaFactura : facturasCache.find(x => String(x.id) === id);
  if (!f) {
    try { facturasCache = await api('/facturas?limite=500'); } catch (err) { toast(err.message); }
    f = facturasCache.find(x => String(x.id) === id);
  }
  if (!f || f.estado !== 'autorizada') { toast('No encontramos esa factura'); go('historial'); return; }
  mostrarFactura(f);
  $('#okBox').hidden = !recienEmitida;
  $('#fTitulo').hidden = recienEmitida;
  $('#fTitulo').textContent = f.tipo_nombre + ' ' + f.numero;
  recienEmitida = false;
  mostrar('factura');
}

function mostrarFactura(f) {
  ultimaFactura = f;
  const vto = f.cae_vto ? f.cae_vto.split('-').reverse().join('/') : '';
  const linea = (k, v) => `<div class="r"><span>${k}</span><b>${v}</b></div>`;
  $('#inv').innerHTML = `
    <div class="hd"><div><b>${esc(me?.nombre)}</b><br><span class="mut">CUIT ${esc(fmtCuit(me?.cuit))} · ${esc(COND_CORTA[me?.condicion_iva] || '')}</span></div><div class="lt">${f.letra}</div></div>`
    + linea('Comprobante', f.numero)
    + linea('Fecha', f.fecha.split('-').reverse().join('/'))
    + linea('Cliente', esc(f.receptor))
    + (f.letra === 'A' ? linea('Condición frente al IVA', esc(f.condicion_iva_receptor)) : '')
    + linea('Concepto', esc(f.detalle))
    + linea('Cond. de venta', esc(f.condicion_venta))
    + (f.letra === 'A' ? linea('Importe sin IVA', fmt(f.importe_neto)) + linea('IVA ' + pctTxt(f.alicuota), fmt(f.importe_iva)) : '')
    + `<div class="tot"><span>Total</span><span>${fmt(f.importe_total)}</span></div>`
    + (f.letra === 'B' ? `<div class="iva-cont">Régimen de Transparencia Fiscal al Consumidor (Ley 27.743) · IVA contenido: <b>${fmt(f.importe_iva)}</b></div>` : '')
    + `<div class="cae">CAE <b>${f.cae}</b> · Vto. ${vto}${f.entorno !== 'produccion' ? '<br><span class="ph">Entorno de ' + f.entorno + ': sin validez fiscal</span>' : ''}</div>`;
}

async function pdfBlob(f) {
  const r = await api(`/facturas/${f.id}/pdf`, {raw: true});
  return new File([await r.blob()], `Factura_${f.letra}_${f.numero}.pdf`, {type: 'application/pdf'});
}
$('#btnVerPdf').onclick = async () => {
  try { const file = await pdfBlob(ultimaFactura); const url = URL.createObjectURL(file); const a = document.createElement('a'); a.href = url; a.download = file.name; a.target = '_blank'; a.click(); setTimeout(() => URL.revokeObjectURL(url), 60000); }
  catch (err) { toast(err.message); }
};
$('#btnCompartir').onclick = async () => {
  try {
    const file = await pdfBlob(ultimaFactura);
    if (navigator.canShare && navigator.canShare({files: [file]})) {
      await navigator.share({files: [file], title: ultimaFactura.tipo_nombre + ' ' + ultimaFactura.numero});
    } else {
      $('#btnVerPdf').click();
      toast('Tu navegador no permite compartir archivos: se descargó el PDF');
    }
  } catch (err) { if (err.name !== 'AbortError') toast(err.message); }
};

/* ---------- Arranque ---------- */
(async () => {
  if (token) { try { await entrar(); return; } catch (e) { /* sesión vencida: se muestra el ingreso */ } }
  render();
})();
