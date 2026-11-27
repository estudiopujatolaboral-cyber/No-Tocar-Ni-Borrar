/* Simulador del servidor de Facturá Fácil (versión de prueba).
   Reemplaza a la API de facturafacil/app (FastAPI + ARCA) para que la app funcione abriendo el archivo,
   sin servidor. Responde lo mismo que app/routers/auth.py y app/routers/cliente.py, con las mismas
   validaciones de app/services/facturacion.py, y genera el PDF con el mismo diseño que app/services/pdf.py.
   Además de la Factura C simula la A y la B (la app real todavía emite solo C): cada cliente emite
   las que le corresponden según su condición frente al IVA (ver EMISORES).
   Los datos se guardan en localStorage. El CAE es inventado: todo sale como "SIN VALIDEZ FISCAL (PRUEBA)". */
(function () {
  'use strict';
  const CLAVE = 'ff_prueba_db';
  const pad = (n, l) => String(n).padStart(l, '0');
  const iso = d => d.getFullYear() + '-' + pad(d.getMonth() + 1, 2) + '-' + pad(d.getDate(), 2);
  const hoy = () => iso(new Date());
  const sumarDias = (f, n) => { const d = new Date(f + 'T12:00:00'); d.setDate(d.getDate() + n); return iso(d); };
  const dif = (a, b) => Math.round((new Date(a + 'T12:00:00') - new Date(b + 'T12:00:00')) / 864e5);
  const fechaAR = f => f ? f.split('-').reverse().join('/') : '';
  const fmtCuit = c => c && c.length === 11 ? c.slice(0, 2) + '-' + c.slice(2, 10) + '-' + c.slice(10) : c;
  const pesos = x => '$ ' + Number(x).toLocaleString('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const r2 = x => Math.round(x * 100) / 100;
  const pctTxt = p => String(p).replace('.', ',') + '%';

  // ---- Tablas (app/arca/constantes.py)
  // Tipos de comprobante de ARCA: 1 = Factura A, 6 = Factura B, 11 = Factura C.
  const TIPOS_CBTE = {
    1: { letra: 'A', nombre: 'Factura A', cod: '001' },
    6: { letra: 'B', nombre: 'Factura B', cod: '006' },
    11: { letra: 'C', nombre: 'Factura C', cod: '011' },
  };
  // Qué facturas emite cada condición frente al IVA del emisor.
  // "Autónomo" no es una condición de IVA: en IVA un autónomo es Responsable Inscripto (o Exento).
  const EMISORES = {
    'IVA Responsable Inscripto': [1, 6],
    'Responsable Monotributo': [11],
    'IVA Sujeto Exento': [11],
  };
  const DOC_TIPOS = { 80: 'CUIT', 86: 'CUIL', 96: 'DNI', 99: 'Sin identificar' };
  const CONCEPTOS = { 1: 'Productos', 2: 'Servicios', 3: 'Productos y servicios' };
  const CONDICIONES_IVA_RECEPTOR = {
    1: 'IVA Responsable Inscripto', 4: 'IVA Sujeto Exento', 5: 'Consumidor Final', 6: 'Responsable Monotributo',
    7: 'Sujeto No Categorizado', 8: 'Proveedor del Exterior', 9: 'Cliente del Exterior', 10: 'IVA Liberado – Ley N° 19.640',
    13: 'Monotributista Social', 15: 'IVA No Alcanzado', 16: 'Monotributo Trabajador Independiente Promovido',
  };
  // Condiciones del cliente que admite cada letra (como FEParamGetCondicionIvaReceptor; verificar con ARCA).
  // A: Responsables Inscriptos y Monotributistas. B: el resto (consumidor final, exento, etc.). C: cualquiera.
  const CONDICIONES_POR_LETRA = { A: [1, 6, 13, 16], B: [4, 5, 7, 9, 10, 15], C: [1, 4, 5, 6, 7, 9, 10, 13, 15, 16] };
  // Alícuotas de IVA con su código de ARCA (FEParamGetTiposIva).
  const ALICUOTAS_IVA = [{ id: 5, pct: 21 }, { id: 4, pct: 10.5 }, { id: 6, pct: 27 }, { id: 8, pct: 5 }, { id: 9, pct: 2.5 }, { id: 3, pct: 0 }];
  const CONDICIONES_VENTA = ['Contado', 'Transferencia Bancaria', 'Tarjeta de Débito', 'Tarjeta de Crédito', 'Otros medios de pago electrónico', 'Cuenta Corriente', 'Cheque', 'Tiquet', 'Otra'];
  const TOPE_CF = 10000000;
  const ESTUDIO = {
    nombre: 'Estudio José A. Quacquarini y Asoc.', whatsapp: '+54 9 3464 69-7225', email: 'contacto@estudioquacquarini.com.ar',
    direccion: 'Castellanos 893, Rosario · Moreno 557, Pujato', horario: 'Lun a Vie · 9 a 17 h',
    instagram: '@estudioquacquarini', url: 'https://estudioquacquarini.com.ar',
  };

  function validarCuit(c) {
    if (!/^\d{11}$/.test(c)) return false;
    const p = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2];
    let s = 0; for (let i = 0; i < 10; i++) s += +c[i] * p[i];
    let dv = 11 - (s % 11); dv = dv === 11 ? 0 : dv === 10 ? 9 : dv;
    return dv === +c[10];
  }
  function caeSimulado() { let s = '7'; for (let i = 0; i < 13; i++) s += Math.floor(Math.random() * 10); return s; }

  // Importes según la letra. A: se carga el importe sin IVA y el IVA se suma.
  // B: se carga el precio final (IVA incluido) y se calcula el IVA contenido. C: no lleva IVA.
  function calcularImportes(tipo, monto, alicuotaId) {
    if (tipo === 11) return { importe_neto: r2(monto), importe_iva: 0, importe_total: r2(monto), alicuota_id: null };
    const pct = ALICUOTAS_IVA.find(a => a.id === alicuotaId).pct / 100;
    if (tipo === 1) {
      const neto = r2(monto), iva = r2(neto * pct);
      return { importe_neto: neto, importe_iva: iva, importe_total: r2(neto + iva), alicuota_id: alicuotaId };
    }
    const total = r2(monto), neto = r2(total / (1 + pct));
    return { importe_neto: neto, importe_iva: r2(total - neto), importe_total: total, alicuota_id: alicuotaId };
  }

  // ---- Datos de ejemplo: un cliente por cada condición frente al IVA
  const ACCESO = { password: 'inicio123', debe_cambiar_password: false, acepto_terminos: true }; // ya activos: entran directo
  const R = (id, doc_tipo, doc_nro, nombre, cond) => ({ id, doc_tipo, doc_nro, nombre, domicilio: '', condicion_iva_receptor_id: cond });

  function armarCuenta(cliente, receptores, plan) {
    // plan: [días atrás, receptor (0 = consumidor final), concepto, importe, condición de venta, tipo de comprobante]
    const numeros = {};
    const facturas = plan.map(([dias, r, detalle, monto, cv, tipo], i) => {
      const rec = r ? receptores[r - 1] : null, fecha = sumarDias(hoy(), -dias);
      numeros[tipo] = (numeros[tipo] || 0) + 1; // cada tipo de comprobante lleva su propia numeración
      return {
        id: i + 1, tipo_cbte: tipo, punto_venta: cliente.punto_venta, numero: numeros[tipo], fecha, concepto: cliente.concepto,
        doc_tipo: rec ? rec.doc_tipo : 99, doc_nro: rec ? rec.doc_nro : '0', receptor_nombre: rec ? rec.nombre : 'Consumidor Final',
        receptor_domicilio: '', condicion_iva_receptor_id: rec ? rec.condicion_iva_receptor_id : 5,
        detalle, ...calcularImportes(tipo, monto, 5), condicion_venta: CONDICIONES_VENTA[cv], estado: 'autorizada',
        cae: caeSimulado(), cae_vto: sumarDias(fecha, 10), observaciones: '', entorno: 'prueba',
      };
    });
    return { cliente, receptores, facturas };
  }

  function datosIniciales() {
    const monotributo = armarCuenta({
      cuit: '20123456786', razon_social: 'Martín Gómez', domicilio: 'San Martín 1250, Rosario, Santa Fe',
      condicion_iva: 'Responsable Monotributo', categoria: 'D', punto_venta: 3, concepto: 2,
      tope_anual: 30628651.43, ajuste_facturado_12m: 1850000, inicio_actividades: '2021-03-01', ...ACCESO,
    }, [
      R(1, 80, '30712345671', 'Distribuidora del Sur S.R.L.', 1), R(2, 80, '27301234568', 'María Laura Gómez', 6),
      R(3, 96, '28456789', 'Juan Pérez', 5), R(4, 80, '20223334440', 'Taller Mecánico Roldán', 1),
    ], [
      [318, 1, 'Honorarios profesionales', 1650000, 1, 11], [290, 2, 'Servicios prestados', 1420000, 4, 11], [262, 0, 'Asesoramiento', 980000, 0, 11],
      [236, 4, 'Mantenimiento mensual', 1750000, 1, 11], [205, 1, 'Honorarios profesionales', 1650000, 1, 11], [178, 3, 'Servicios prestados', 1210000, 4, 11],
      [150, 2, 'Servicios prestados', 1500000, 1, 11], [121, 0, 'Asesoramiento', 1100000, 0, 11], [93, 4, 'Mantenimiento mensual', 1850000, 1, 11],
      [64, 1, 'Honorarios profesionales', 1980000, 1, 11], [35, 2, 'Servicios prestados', 1640000, 4, 11], [9, 3, 'Servicios prestados', 1320000, 4, 11],
    ]);
    const inscripto = armarCuenta({
      cuit: '27234567891', razon_social: 'Carolina Ruiz', domicilio: 'Córdoba 1840, Rosario, Santa Fe',
      condicion_iva: 'IVA Responsable Inscripto', categoria: '', punto_venta: 2, concepto: 2,
      tope_anual: 0, ajuste_facturado_12m: 0, inicio_actividades: '2016-08-01', ...ACCESO,
    }, [
      R(1, 80, '30712345671', 'Distribuidora del Sur S.R.L.', 1), R(2, 80, '20223334440', 'Taller Mecánico Roldán', 1),
      R(3, 80, '27301234568', 'María Laura Gómez', 6), R(4, 80, '30555666779', 'Club Atlético Pujato', 4),
      R(5, 96, '28456789', 'Juan Pérez', 5),
    ], [ // en la A el importe es sin IVA; en la B, el precio final
      [115, 1, 'Servicios de consultoría', 1200000, 1, 1], [98, 3, 'Honorarios profesionales', 450000, 1, 1], [84, 5, 'Asesoramiento técnico', 180000, 0, 6],
      [70, 2, 'Servicios de consultoría', 950000, 1, 1], [61, 0, 'Asesoramiento técnico', 120000, 4, 6], [45, 4, 'Honorarios profesionales', 300000, 1, 6],
      [33, 1, 'Servicios de consultoría', 1200000, 1, 1], [26, 3, 'Honorarios profesionales', 480000, 4, 1], [18, 0, 'Asesoramiento técnico', 150000, 0, 6],
      [12, 2, 'Servicios de consultoría', 990000, 1, 1], [6, 5, 'Asesoramiento técnico', 210000, 4, 6], [2, 1, 'Servicios de consultoría', 1250000, 1, 1],
    ]);
    const exento = armarCuenta({
      cuit: '20301234563', razon_social: 'Pablo Sosa', domicilio: 'Belgrano 420, Pujato, Santa Fe',
      condicion_iva: 'IVA Sujeto Exento', categoria: '', punto_venta: 1, concepto: 2,
      tope_anual: 0, ajuste_facturado_12m: 0, inicio_actividades: '2019-04-01', ...ACCESO,
    }, [
      R(1, 96, '28456789', 'Juan Pérez', 5), R(2, 80, '30555666779', 'Club Atlético Pujato', 4),
      R(3, 80, '30712345671', 'Distribuidora del Sur S.R.L.', 1),
    ], [
      [140, 2, 'Servicios de enseñanza', 380000, 1, 11], [110, 1, 'Clases particulares', 95000, 0, 11], [80, 3, 'Curso de capacitación', 620000, 1, 11],
      [52, 2, 'Servicios de enseñanza', 380000, 1, 11], [24, 1, 'Clases particulares', 95000, 4, 11], [5, 2, 'Servicios de enseñanza', 420000, 1, 11],
    ]);
    const cuentas = {};
    [monotributo, inscripto, exento].forEach(c => { cuentas[c.cliente.cuit] = c; });
    return { v: VERSION, token: null, sesion: null, cuentas };
  }

  // Al cambiar los datos de ejemplo se sube la versión: lo guardado con una versión anterior se descarta.
  const VERSION = 3;
  let db;
  function cargar() { try { const j = JSON.parse(localStorage.getItem(CLAVE)); if (j && j.v === VERSION) return j; } catch (e) {} return datosIniciales(); }
  function guardar() { try { localStorage.setItem(CLAVE, JSON.stringify(db)); } catch (e) { /* sin almacenamiento: queda en memoria */ } }
  db = cargar(); guardar();

  // ---- Respuestas con la forma de fetch()
  class ErrorHttp extends Error { constructor(status, detail) { super(typeof detail === 'string' ? detail : 'Error'); this.status = status; this.detail = detail; } }
  const respuesta = (status, cuerpo, blob) => ({
    status, ok: status >= 200 && status < 300,
    json: async () => cuerpo, blob: async () => blob,
  });
  const espera = ms => new Promise(r => setTimeout(r, ms));

  function autenticar(headers) {
    const h = (headers && (headers.Authorization || headers.authorization)) || '';
    const cta = db.cuentas[db.sesion];
    if (!db.token || h !== 'Bearer ' + db.token || !cta) throw new ErrorHttp(401, 'Sesión inválida');
    return cta;
  }
  function facturado12m(cta) {
    const desde = sumarDias(hoy(), -365);
    return cta.facturas.filter(f => f.estado === 'autorizada' && f.fecha > desde).reduce((s, f) => s + f.importe_total, 0) + (cta.cliente.ajuste_facturado_12m || 0);
  }
  const facturaDict = f => ({
    id: f.id, tipo_cbte: f.tipo_cbte, letra: TIPOS_CBTE[f.tipo_cbte].letra, tipo_nombre: TIPOS_CBTE[f.tipo_cbte].nombre,
    numero: pad(f.punto_venta, 5) + '-' + pad(f.numero, 8), fecha: f.fecha, receptor: f.receptor_nombre,
    doc_tipo: f.doc_tipo, doc_nro: f.doc_nro, condicion_iva_receptor: CONDICIONES_IVA_RECEPTOR[f.condicion_iva_receptor_id] || '',
    detalle: f.detalle, importe_neto: f.importe_neto, importe_iva: f.importe_iva,
    alicuota: f.alicuota_id ? ALICUOTAS_IVA.find(a => a.id === f.alicuota_id).pct : null,
    importe_total: f.importe_total, condicion_venta: f.condicion_venta,
    estado: f.estado, cae: f.cae, cae_vto: f.cae_vto, observaciones: f.observaciones, entorno: f.entorno,
  });

  function emitir(cta, d) {
    const c = cta.cliente, permitidos = EMISORES[c.condicion_iva] || [11], fecha = d.fecha || hoy();
    let docTipo = Number(d.doc_tipo == null ? 99 : d.doc_tipo), docNro = String(d.doc_nro == null ? '0' : d.doc_nro).replace(/[-.]/g, '').trim();
    let nombre = d.receptor_nombre == null ? 'Consumidor Final' : String(d.receptor_nombre);
    const cond = Number(d.condicion_iva_receptor_id == null ? 5 : d.condicion_iva_receptor_id), detalle = String(d.detalle || '');
    const condVenta = d.condicion_venta || 'Contado';
    if (!detalle.trim() || detalle.length > 500) throw new ErrorHttp(422, [{ msg: 'Falta el concepto/detalle' }]);
    if (c.debe_cambiar_password) throw new ErrorHttp(403, 'Antes de facturar tenés que cambiar la contraseña inicial');
    if (!CONDICIONES_VENTA.includes(condVenta)) throw new ErrorHttp(422, 'Condición de venta inválida');
    if (!CONDICIONES_IVA_RECEPTOR[cond]) throw new ErrorHttp(422, 'Condición frente al IVA del receptor inválida');
    if (!DOC_TIPOS[docTipo]) throw new ErrorHttp(422, 'Tipo de documento inválido');

    // Letra: si no viene, se elige por la condición del emisor y la del cliente
    const tipo = d.tipo_cbte == null
      ? (permitidos.length === 1 ? permitidos[0] : CONDICIONES_POR_LETRA.A.includes(cond) ? 1 : 6)
      : Number(d.tipo_cbte);
    if (!TIPOS_CBTE[tipo]) throw new ErrorHttp(422, 'Tipo de comprobante inválido');
    if (!permitidos.includes(tipo)) throw new ErrorHttp(422, `Siendo ${c.condicion_iva} no podés emitir ${TIPOS_CBTE[tipo].nombre}: te corresponde ${permitidos.map(t => TIPOS_CBTE[t].nombre).join(' o ')}`);
    const letra = TIPOS_CBTE[tipo].letra;
    if (!CONDICIONES_POR_LETRA[letra].includes(cond)) {
      throw new ErrorHttp(422, letra === 'A' ? 'La Factura A es para clientes Responsables Inscriptos o Monotributistas: a este cliente le corresponde Factura B'
        : letra === 'B' ? 'A un cliente Responsable Inscripto o Monotributista le corresponde Factura A'
        : 'Condición frente al IVA del receptor inválida');
    }

    // Importes
    let alicuota = null;
    if (letra !== 'C') {
      alicuota = Number(d.alicuota_id == null ? 5 : d.alicuota_id);
      if (!ALICUOTAS_IVA.some(a => a.id === alicuota)) throw new ErrorHttp(422, 'Alícuota de IVA inválida');
    }
    const monto = Number(letra === 'A' ? d.importe_neto : d.importe_total);
    if (!(monto > 0)) throw new ErrorHttp(422, [{ msg: 'El importe debe ser mayor a cero' }]);
    const imp = calcularImportes(tipo, monto, alicuota);

    if (docTipo === 99) {
      docNro = '0'; nombre = nombre || 'Consumidor Final';
      if (cond !== 5) throw new ErrorHttp(422, 'Sin identificar solo corresponde a consumidor final');
      if (imp.importe_total >= TOPE_CF) throw new ErrorHttp(422, 'Por el monto, hay que identificar al consumidor final (DNI o CUIT)');
    } else if (docTipo === 80 || docTipo === 86) {
      if (!validarCuit(docNro)) throw new ErrorHttp(422, 'El CUIT/CUIL del receptor no es válido');
    } else if (docTipo === 96 && !/^\d{6,8}$/.test(docNro)) throw new ErrorHttp(422, 'El DNI no es válido');
    if ([1, 6, 13, 16].includes(cond) && docTipo !== 80) throw new ErrorHttp(422, 'Para esa condición frente al IVA hay que informar el CUIT');
    const margen = c.concepto === 1 ? 5 : 10;
    if (Math.abs(dif(fecha, hoy())) > margen) throw new ErrorHttp(422, `La fecha debe estar dentro de ±${margen} días de hoy`);

    // Cada letra tiene su propia numeración en ARCA
    const numero = cta.facturas.filter(f => f.punto_venta === c.punto_venta && f.tipo_cbte === tipo).reduce((m, f) => Math.max(m, f.numero), 0) + 1;
    const f = {
      id: cta.facturas.reduce((m, x) => Math.max(m, x.id), 0) + 1, tipo_cbte: tipo, punto_venta: c.punto_venta, numero, fecha, concepto: c.concepto,
      doc_tipo: docTipo, doc_nro: docNro, receptor_nombre: nombre.trim(), receptor_domicilio: d.receptor_domicilio || '',
      condicion_iva_receptor_id: cond, detalle: detalle.trim(), ...imp, condicion_venta: condVenta,
      estado: 'autorizada', cae: caeSimulado(), cae_vto: sumarDias(fecha, 10), observaciones: '', entorno: 'prueba',
    };
    cta.facturas.push(f);
    if (d.guardar_receptor !== false && docTipo !== 99 && !cta.receptores.some(r => r.doc_tipo === docTipo && r.doc_nro === docNro)) {
      cta.receptores.push({ id: cta.receptores.reduce((m, r) => Math.max(m, r.id), 0) + 1, doc_tipo: docTipo, doc_nro: docNro, nombre: f.receptor_nombre, domicilio: f.receptor_domicilio, condicion_iva_receptor_id: cond });
    }
    guardar();
    return facturaDict(f);
  }

  // ---- PDF con el mismo diseño que app/services/pdf.py (A4, medidas en mm)
  function generarPdf(cta, f) {
    if (!window.jspdf) throw new ErrorHttp(503, 'Para generar el PDF hace falta conexión a internet. Probá de nuevo con conexión.');
    const c = cta.cliente, T = TIPOS_CBTE[f.tipo_cbte], { jsPDF } = window.jspdf, pdf = new jsPDF({ unit: 'mm', format: 'a4' });
    const W = 210, m = 15, t = s => String(s).replace(/–/g, '-');
    const nro = pad(f.punto_venta, 5) + '-' + pad(f.numero, 8);
    const alic = f.alicuota_id ? ALICUOTAS_IVA.find(a => a.id === f.alicuota_id).pct : 0;
    pdf.setProperties({ title: T.nombre + ' ' + nro });
    pdf.setLineWidth(0.3);
    pdf.setFont('helvetica', 'bold'); pdf.setFontSize(10); pdf.text('ORIGINAL', W / 2, m, { align: 'center' });
    const top = m + 6;
    pdf.rect(m, top, W - 2 * m, 45); pdf.line(W / 2, top + 14, W / 2, top + 45);
    pdf.rect(W / 2 - 8, top, 16, 14);
    pdf.setFontSize(22); pdf.text(T.letra, W / 2, top + 10, { align: 'center' });
    pdf.setFont('helvetica', 'normal'); pdf.setFontSize(6); pdf.text('COD. ' + T.cod, W / 2, top + 13, { align: 'center' });
    // Emisor
    pdf.setFont('helvetica', 'bold'); pdf.setFontSize(13); pdf.text(t(c.razon_social).slice(0, 40), m + 4, top + 8);
    pdf.setFont('helvetica', 'normal'); pdf.setFontSize(8.5);
    pdf.text(t('Domicilio: ' + c.domicilio).slice(0, 70), m + 4, top + 20);
    pdf.text(t('Condición frente al IVA: ' + c.condicion_iva).slice(0, 70), m + 4, top + 25);
    // Comprobante
    const x = W / 2 + 12;
    pdf.setFont('helvetica', 'bold'); pdf.setFontSize(14); pdf.text('FACTURA', x, top + 6);
    pdf.setFont('helvetica', 'normal'); pdf.setFontSize(8.5);
    [`Punto de venta: ${pad(f.punto_venta, 5)}    Comp. Nro: ${pad(f.numero, 8)}`, `Fecha de emisión: ${fechaAR(f.fecha)}`,
      `CUIT: ${fmtCuit(c.cuit)}`, `Ingresos Brutos: ${c.cuit}`, `Inicio de actividades: ${fechaAR(c.inicio_actividades)}`]
      .forEach((l, i) => pdf.text(l, x, top + 6 + 5.5 * (i + 1)));
    // Período (servicios)
    let y = top + 45;
    if (f.concepto === 2 || f.concepto === 3) {
      const [a, mm] = f.fecha.split('-'), ultimo = new Date(+a, +mm, 0).getDate();
      pdf.rect(m, y, W - 2 * m, 8);
      pdf.text(`Período facturado desde: 01/${mm}/${a}   hasta: ${pad(ultimo, 2)}/${mm}/${a}   Vto. para el pago: ${fechaAR(f.fecha)}`, m + 4, y + 5.5);
      y += 8;
    }
    // Receptor
    pdf.rect(m, y, W - 2 * m, 20);
    const doc = f.doc_tipo === 99 ? '' : `${DOC_TIPOS[f.doc_tipo]}: ${f.doc_tipo === 80 || f.doc_tipo === 86 ? fmtCuit(f.doc_nro) : f.doc_nro}`;
    pdf.text(doc, m + 4, y + 6);
    pdf.text(t('Apellido y Nombre / Razón Social: ' + f.receptor_nombre).slice(0, 60), W / 2, y + 6);
    pdf.text(t('Condición frente al IVA: ' + (CONDICIONES_IVA_RECEPTOR[f.condicion_iva_receptor_id] || '')), m + 4, y + 12);
    pdf.text(t('Domicilio: ' + (f.receptor_domicilio || '')).slice(0, 60), W / 2, y + 12);
    pdf.text(t('Condición de venta: ' + f.condicion_venta), m + 4, y + 18);
    y += 20;
    // Detalle (en la A el subtotal va sin IVA; en la B y la C, con el precio final)
    y += 8;
    pdf.setFillColor(217, 217, 217); pdf.rect(m, y - 5, W - 2 * m, 7, 'F');
    pdf.setFont('helvetica', 'bold'); pdf.setFontSize(8.5);
    pdf.text(`${CONCEPTOS[f.concepto] || 'Concepto'} / Descripción`, m + 3, y);
    if (T.letra === 'A') pdf.text('Alícuota IVA', W - m - 45, y, { align: 'right' });
    pdf.text('Subtotal', W - m - 3, y, { align: 'right' });
    pdf.setFont('helvetica', 'normal'); pdf.setFontSize(9);
    y += 9;
    pdf.text(t(f.detalle).slice(0, T.letra === 'A' ? 60 : 95), m + 3, y);
    if (T.letra === 'A') pdf.text(pctTxt(alic), W - m - 45, y, { align: 'right' });
    pdf.text(pesos(T.letra === 'A' ? f.importe_neto : f.importe_total), W - m - 3, y, { align: 'right' });
    // Totales
    if (T.letra === 'A') {
      pdf.rect(m, 194, W - 2 * m, 28);
      pdf.setFontSize(9.5);
      pdf.text('Importe Neto Gravado:', W - m - 80, 201); pdf.text(pesos(f.importe_neto), W - m - 4, 201, { align: 'right' });
      pdf.text(`IVA ${pctTxt(alic)}:`, W - m - 80, 208); pdf.text(pesos(f.importe_iva), W - m - 4, 208, { align: 'right' });
      pdf.setFont('helvetica', 'bold'); pdf.setFontSize(11);
      pdf.text('Importe Total:', W - m - 80, 217); pdf.text(pesos(f.importe_total), W - m - 4, 217, { align: 'right' });
    } else {
      pdf.rect(m, 204, W - 2 * m, 18);
      pdf.setFont('helvetica', 'bold'); pdf.setFontSize(11);
      pdf.text('Importe Total:', W - m - 80, 215);
      pdf.text(pesos(f.importe_total), W - m - 4, 215, { align: 'right' });
      if (T.letra === 'B') { // Ley 27.743: en la B se informa el IVA contenido en el precio
        pdf.setFontSize(7.5); pdf.text('Régimen de Transparencia Fiscal al Consumidor (Ley 27.743)', m + 4, 209.5);
        pdf.setFont('helvetica', 'normal');
        pdf.text('IVA Contenido: ' + pesos(f.importe_iva), m + 4, 214);
        pdf.text('Otros Impuestos Nacionales Indirectos: ' + pesos(0), m + 4, 218.5);
      }
    }
    // QR + CAE
    pdf.setDrawColor(150); pdf.setLineDashPattern([1.5, 1.5], 0); pdf.rect(m, 232, 45, 45); pdf.setLineDashPattern([], 0); pdf.setDrawColor(0);
    pdf.setFont('helvetica', 'normal'); pdf.setFontSize(7); pdf.setTextColor(120);
    pdf.text(['QR de ARCA', '(se genera con', 'el CAE real)'], m + 22.5, 251, { align: 'center' });
    pdf.setTextColor(0);
    pdf.setFont('helvetica', 'bold'); pdf.setFontSize(9); pdf.text('Comprobante Autorizado', m + 50, 245);
    pdf.setFont('helvetica', 'normal'); pdf.setFontSize(7.5);
    pdf.text('Esta Agencia no se responsabiliza por los datos ingresados en el detalle de la operación', m + 50, 267);
    pdf.setFont('helvetica', 'bold'); pdf.setFontSize(10);
    pdf.text(`CAE N°: ${f.cae}`, W - m, 245, { align: 'right' });
    pdf.text(`Fecha de Vto. de CAE: ${fechaAR(f.cae_vto)}`, W - m, 251, { align: 'right' });
    // Marca de agua (fuera de producción)
    pdf.saveGraphicsState();
    pdf.setGState(new pdf.GState({ opacity: 0.5 }));
    pdf.setTextColor(217, 51, 51); pdf.setFontSize(24);
    pdf.text('SIN VALIDEZ FISCAL (PRUEBA)', W / 2, 168, { align: 'center', angle: 25 });
    pdf.restoreGraphicsState();
    return pdf.output('blob');
  }

  // ---- Enrutador: misma API que el servidor
  async function atender(url, opts) {
    const u = new URL(url, 'http://local'), path = u.pathname, metodo = (opts.method || 'GET').toUpperCase();
    const body = opts.body ? JSON.parse(opts.body) : {}, headers = opts.headers || {};
    let m;
    if (path === '/api/auth/login' && metodo === 'POST') {
      const usuario = String(body.usuario || '').trim().replace(/-/g, ''), cta = db.cuentas[usuario];
      if (!cta || body.password !== cta.cliente.password) throw new ErrorHttp(401, 'Usuario o contraseña incorrectos');
      db.token = 'prueba-' + Date.now().toString(36) + Math.random().toString(36).slice(2); db.sesion = usuario; guardar();
      return { token: db.token, rol: 'cliente', nombre: cta.cliente.razon_social, debe_cambiar_password: cta.cliente.debe_cambiar_password };
    }
    if (path === '/api/parametros') {
      return {
        condiciones_venta: CONDICIONES_VENTA,
        condiciones_iva_receptor: Object.entries(CONDICIONES_IVA_RECEPTOR).map(([id, nombre]) => ({ id: +id, nombre })),
        condiciones_por_letra: CONDICIONES_POR_LETRA,
        alicuotas_iva: ALICUOTAS_IVA,
        tipos_cbte: Object.entries(TIPOS_CBTE).map(([id, t]) => ({ id: +id, letra: t.letra, nombre: t.nombre })),
        doc_tipos: Object.entries(DOC_TIPOS).map(([id, nombre]) => ({ id: +id, nombre })),
        tope_consumidor_final: TOPE_CF, entorno: 'prueba', estudio: ESTUDIO,
      };
    }
    const cta = autenticar(headers), c = cta.cliente;
    if (path === '/api/auth/cambiar-password' && metodo === 'POST') {
      if (String(body.nueva || '').length < 8) throw new ErrorHttp(422, [{ msg: 'La nueva contraseña tiene que tener al menos 8 caracteres' }]);
      if (body.actual !== c.password) throw new ErrorHttp(400, 'La contraseña actual no es correcta');
      if (!c.acepto_terminos) { if (!body.acepto_terminos) throw new ErrorHttp(400, 'Tenés que aceptar los términos de uso'); c.acepto_terminos = true; }
      c.password = body.nueva; c.debe_cambiar_password = false; guardar();
      return { ok: true };
    }
    if (path === '/api/me') {
      const mes = hoy().slice(0, 7), delMes = cta.facturas.filter(f => f.estado === 'autorizada' && f.fecha.startsWith(mes));
      return {
        nombre: c.razon_social, cuit: c.cuit, condicion_iva: c.condicion_iva, categoria: c.categoria, punto_venta: c.punto_venta,
        tipos_cbte: (EMISORES[c.condicion_iva] || [11]).map(t => ({ id: t, letra: TIPOS_CBTE[t].letra, nombre: TIPOS_CBTE[t].nombre })),
        tope_anual: c.tope_anual, facturado_12m: facturado12m(cta),
        facturado_mes_neto: r2(delMes.reduce((s, f) => s + f.importe_neto, 0)), iva_debito_mes: r2(delMes.reduce((s, f) => s + f.importe_iva, 0)),
        debe_cambiar_password: c.debe_cambiar_password, acepto_terminos: c.acepto_terminos,
      };
    }
    if (path === '/api/facturas' && metodo === 'GET') {
      const limite = Math.min(+(u.searchParams.get('limite') || 50), 500);
      return cta.facturas.slice().sort((a, b) => b.id - a.id).slice(0, limite).map(facturaDict);
    }
    if (path === '/api/facturas' && metodo === 'POST') { await espera(1600); return emitir(cta, body); }
    if ((m = path.match(/^\/api\/facturas\/(\d+)\/pdf$/))) {
      const f = cta.facturas.find(x => x.id === +m[1]);
      if (!f) throw new ErrorHttp(404, 'No existe');
      if (f.estado !== 'autorizada') throw new ErrorHttp(409, 'La factura no está autorizada');
      return { __blob: generarPdf(cta, f) };
    }
    if (path === '/api/receptores' && metodo === 'GET') return cta.receptores.slice().sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'));
    throw new ErrorHttp(404, 'Not Found');
  }

  window.Simulador = {
    async fetch(url, opts = {}) {
      await espera(150);
      try {
        const r = await atender(url, opts);
        return r && r.__blob ? respuesta(200, null, r.__blob) : respuesta(200, r);
      } catch (e) {
        if (e instanceof ErrorHttp) return respuesta(e.status, { detail: e.detail });
        return respuesta(500, { detail: 'Error interno del simulador: ' + e.message });
      }
    },
    reiniciar() { db = datosIniciales(); guardar(); },
  };
})();
