// Minimal dependency-free 3D preview for STL / 3MF / OBJ — the web equivalent
// of the macOS app's SceneKit preview sheet (ModelPreviewSheet/SceneKitPreview
// in ProjectDetailView.swift): mouse-drag orbit, scroll-wheel zoom, a single
// directional light. No external library, no CDN — a compact hand-rolled
// WebGL1 renderer, since this is a preview tool, not a modeling app.
"use strict";

// ───────────────────────── Public entry point ─────────────────────────

function openViewer3D(fileId, fileName, kind) {
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay viewer-overlay";
  overlay.innerHTML = `
    <div class="modal viewer-modal">
      <div class="viewer-toolbar">
        <span class="viewer-title">${escapeHtml(fileName)}</span>
        <button class="btn btn-sm" id="btnCloseViewer">Fermer</button>
      </div>
      <div class="viewer-canvas-wrap">
        <canvas id="viewerCanvas"></canvas>
        <div class="viewer-message" id="viewerMessage">Chargement…</div>
      </div>
    </div>`;
  document.body.appendChild(overlay);

  const close = () => overlay.remove();
  overlay.querySelector("#btnCloseViewer").addEventListener("click", close);
  overlay.addEventListener("click", (evt) => { if (evt.target === overlay) close(); });
  document.addEventListener("keydown", function escHandler(evt) {
    if (evt.key === "Escape") { close(); document.removeEventListener("keydown", escHandler); }
  });

  const canvas = overlay.querySelector("#viewerCanvas");
  const msg = overlay.querySelector("#viewerMessage");

  v3dLoad(fileId, kind)
    .then((mesh) => {
      if (!mesh || mesh.positions.length === 0) {
        msg.textContent = "Aperçu non disponible\npour ce format";
        return;
      }
      msg.style.display = "none";
      try {
        v3dStart(canvas, mesh);
      } catch (e) {
        msg.style.display = "block";
        msg.textContent = `Aperçu indisponible : ${e.message}`;
      }
    })
    .catch((e) => {
      msg.textContent = `Erreur : ${e.message}`;
    });
}

// ───────────────────────── Loading & parsing ─────────────────────────

async function v3dLoad(fileId, kind) {
  if (kind !== "stl" && kind !== "threeMF" && kind !== "obj") return null;
  const res = await fetch(`/api/files/${fileId}/download`);
  if (!res.ok) throw new Error("téléchargement impossible");
  if (kind === "obj") return v3dParseOBJ(await res.text());
  const buffer = await res.arrayBuffer();
  if (kind === "stl") return v3dParseSTL(buffer);
  return await v3dParse3MF(buffer);
}

// -- STL (binary or ASCII) --

function v3dParseSTL(buffer) {
  if (buffer.byteLength >= 84) {
    const dv = new DataView(buffer);
    const triCount = dv.getUint32(80, true);
    if (84 + triCount * 50 === buffer.byteLength) {
      return v3dParseBinarySTL(dv, triCount);
    }
  }
  return v3dParseAsciiSTL(new TextDecoder().decode(buffer));
}

function v3dParseBinarySTL(dv, triCount) {
  const positions = new Float32Array(triCount * 9);
  const normals = new Float32Array(triCount * 9);
  let offset = 84;
  for (let i = 0; i < triCount; i++) {
    const nx = dv.getFloat32(offset, true), ny = dv.getFloat32(offset + 4, true), nz = dv.getFloat32(offset + 8, true);
    offset += 12;
    for (let v = 0; v < 3; v++) {
      const x = dv.getFloat32(offset, true), y = dv.getFloat32(offset + 4, true), z = dv.getFloat32(offset + 8, true);
      offset += 12;
      const idx = (i * 3 + v) * 3;
      positions[idx] = x; positions[idx + 1] = y; positions[idx + 2] = z;
      normals[idx] = nx; normals[idx + 1] = ny; normals[idx + 2] = nz;
    }
    offset += 2; // attribute byte count, unused
  }
  return { positions, normals };
}

function v3dParseAsciiSTL(text) {
  const positions = [];
  const normals = [];
  const facetRe = /facet\s+normal\s+(\S+)\s+(\S+)\s+(\S+)[\s\S]*?vertex\s+(\S+)\s+(\S+)\s+(\S+)\s+vertex\s+(\S+)\s+(\S+)\s+(\S+)\s+vertex\s+(\S+)\s+(\S+)\s+(\S+)/g;
  let m;
  while ((m = facetRe.exec(text))) {
    const n = m.slice(1).map(Number);
    positions.push(n[3], n[4], n[5], n[6], n[7], n[8], n[9], n[10], n[11]);
    normals.push(n[0], n[1], n[2], n[0], n[1], n[2], n[0], n[1], n[2]);
  }
  return { positions: new Float32Array(positions), normals: new Float32Array(normals) };
}

// -- OBJ (v / f lines, fan-triangulated) --

function v3dParseOBJ(text) {
  const verts = [];
  const positions = [];
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (line.startsWith("v ")) {
      const p = line.split(/\s+/);
      verts.push([parseFloat(p[1]), parseFloat(p[2]), parseFloat(p[3])]);
    } else if (line.startsWith("f ")) {
      const idx = line.split(/\s+/).slice(1).map((tok) => parseInt(tok.split("/")[0], 10) - 1);
      for (let i = 1; i < idx.length - 1; i++) {
        const a = verts[idx[0]], b = verts[idx[i]], c = verts[idx[i + 1]];
        if (a && b && c) positions.push(...a, ...b, ...c);
      }
    }
  }
  const positionsArr = new Float32Array(positions);
  return { positions: positionsArr, normals: v3dComputeFaceNormals(positionsArr) };
}

// -- 3MF (ZIP + XML) — renders every <object type="model"> mesh; doesn't
// bother resolving BambuStudio multi-plate metadata like the server parser
// does, since this is just a visual preview, not an estimate input. --

async function v3dParse3MF(buffer) {
  const entries = await v3dUnzip(buffer);
  const modelName = Object.keys(entries).find((k) => k.toLowerCase().endsWith("3dmodel.model"));
  if (!modelName) return null;
  const xmlText = new TextDecoder().decode(entries[modelName]);
  const xml = new DOMParser().parseFromString(xmlText, "application/xml");

  const positions = [];
  for (const obj of xml.getElementsByTagName("object")) {
    const type = (obj.getAttribute("type") || "model").toLowerCase();
    if (type !== "model") continue;
    for (const mesh of obj.getElementsByTagName("mesh")) {
      const vertices = [];
      for (const v of mesh.getElementsByTagName("vertex")) {
        vertices.push([parseFloat(v.getAttribute("x")), parseFloat(v.getAttribute("y")), parseFloat(v.getAttribute("z"))]);
      }
      for (const t of mesh.getElementsByTagName("triangle")) {
        const a = vertices[parseInt(t.getAttribute("v1"), 10)];
        const b = vertices[parseInt(t.getAttribute("v2"), 10)];
        const c = vertices[parseInt(t.getAttribute("v3"), 10)];
        if (a && b && c) positions.push(...a, ...b, ...c);
      }
    }
  }
  const positionsArr = new Float32Array(positions);
  return { positions: positionsArr, normals: v3dComputeFaceNormals(positionsArr) };
}

function v3dComputeFaceNormals(positions) {
  const normals = new Float32Array(positions.length);
  for (let i = 0; i < positions.length; i += 9) {
    const ax = positions[i], ay = positions[i + 1], az = positions[i + 2];
    const bx = positions[i + 3], by = positions[i + 4], bz = positions[i + 5];
    const cx = positions[i + 6], cy = positions[i + 7], cz = positions[i + 8];
    const ux = bx - ax, uy = by - ay, uz = bz - az;
    const vx = cx - ax, vy = cy - ay, vz = cz - az;
    let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    const len = Math.hypot(nx, ny, nz) || 1;
    nx /= len; ny /= len; nz /= len;
    for (let k = 0; k < 3; k++) { normals[i + k * 3] = nx; normals[i + k * 3 + 1] = ny; normals[i + k * 3 + 2] = nz; }
  }
  return normals;
}

// -- Minimal ZIP reader (stored + deflate, via the native DecompressionStream
// so no inflate implementation is needed in JS) — mirrors ThreeMFParser's
// ZipReader on the Swift side. --

async function v3dUnzip(buffer) {
  const dv = new DataView(buffer);
  const bytes = new Uint8Array(buffer);
  let eocdOffset = -1;
  const searchFrom = Math.max(0, buffer.byteLength - 65558);
  for (let i = buffer.byteLength - 22; i >= searchFrom; i--) {
    if (dv.getUint32(i, true) === 0x06054b50) { eocdOffset = i; break; }
  }
  if (eocdOffset === -1) throw new Error("archive ZIP invalide");

  const entryCount = dv.getUint16(eocdOffset + 10, true);
  let cdOffset = dv.getUint32(eocdOffset + 16, true);
  const result = {};

  for (let i = 0; i < entryCount; i++) {
    if (dv.getUint32(cdOffset, true) !== 0x02014b50) break;
    const method = dv.getUint16(cdOffset + 10, true);
    const compSize = dv.getUint32(cdOffset + 20, true);
    const nameLen = dv.getUint16(cdOffset + 28, true);
    const extraLen = dv.getUint16(cdOffset + 30, true);
    const commentLen = dv.getUint16(cdOffset + 32, true);
    const localOffset = dv.getUint32(cdOffset + 42, true);
    const name = new TextDecoder().decode(bytes.subarray(cdOffset + 46, cdOffset + 46 + nameLen));

    const lfNameLen = dv.getUint16(localOffset + 26, true);
    const lfExtraLen = dv.getUint16(localOffset + 28, true);
    const dataStart = localOffset + 30 + lfNameLen + lfExtraLen;
    const raw = bytes.subarray(dataStart, dataStart + compSize);

    if (method === 0) {
      result[name] = raw;
    } else if (method === 8 && typeof DecompressionStream !== "undefined") {
      result[name] = await v3dInflateRaw(raw);
    }
    cdOffset += 46 + nameLen + extraLen + commentLen;
  }
  return result;
}

async function v3dInflateRaw(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

// ───────────────────────── Tiny matrix helpers (column-major mat4) ─────────────────────────

function v3dIdentity() { return new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]); }

function v3dMultiply(a, b) {
  const out = new Float32Array(16);
  for (let c = 0; c < 4; c++) {
    for (let r = 0; r < 4; r++) {
      let sum = 0;
      for (let k = 0; k < 4; k++) sum += a[k * 4 + r] * b[c * 4 + k];
      out[c * 4 + r] = sum;
    }
  }
  return out;
}

function v3dTranslate(m, x, y, z) {
  const t = v3dIdentity();
  t[12] = x; t[13] = y; t[14] = z;
  return v3dMultiply(m, t);
}

function v3dRotateX(m, a) {
  const c = Math.cos(a), s = Math.sin(a);
  return v3dMultiply(m, new Float32Array([1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1]));
}

function v3dRotateY(m, a) {
  const c = Math.cos(a), s = Math.sin(a);
  return v3dMultiply(m, new Float32Array([c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1]));
}

function v3dPerspective(fovy, aspect, near, far) {
  const f = 1 / Math.tan(fovy / 2);
  const nf = 1 / (near - far);
  return new Float32Array([f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, (far + near) * nf, -1, 0, 0, 2 * far * near * nf, 0]);
}

// Our modelview only ever rotates + translates (no scaling), so the 3x3
// rotation block is orthonormal and is its own inverse-transpose — no need
// for a general matrix inverse just to light the mesh correctly.
function v3dNormalMatrix(m) {
  return new Float32Array([m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]]);
}

function v3dBounds(positions) {
  const min = [Infinity, Infinity, Infinity], max = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < positions.length; i += 3) {
    for (let k = 0; k < 3; k++) {
      const v = positions[i + k];
      if (v < min[k]) min[k] = v;
      if (v > max[k]) max[k] = v;
    }
  }
  return { min, max };
}

// ───────────────────────── WebGL rendering ─────────────────────────

function v3dCompileShader(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const info = gl.getShaderInfoLog(shader);
    gl.deleteShader(shader);
    throw new Error(`shader : ${info}`);
  }
  return shader;
}

function v3dCreateProgram(gl, vsSource, fsSource) {
  const vs = v3dCompileShader(gl, gl.VERTEX_SHADER, vsSource);
  const fs = v3dCompileShader(gl, gl.FRAGMENT_SHADER, fsSource);
  const program = gl.createProgram();
  gl.attachShader(program, vs);
  gl.attachShader(program, fs);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(`linkage : ${gl.getProgramInfoLog(program)}`);
  }
  return program;
}

function v3dResizeCanvas(canvas) {
  const rect = canvas.parentElement.getBoundingClientRect();
  const w = Math.max(200, Math.floor(rect.width));
  const h = Math.max(200, Math.floor(rect.height));
  if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
}

const V3D_VERTEX_SHADER = `
  attribute vec3 aPosition;
  attribute vec3 aNormal;
  uniform mat4 uModelView;
  uniform mat4 uProjection;
  uniform mat3 uNormalMatrix;
  varying vec3 vNormal;
  void main() {
    gl_Position = uProjection * uModelView * vec4(aPosition, 1.0);
    vNormal = uNormalMatrix * aNormal;
  }
`;
const V3D_FRAGMENT_SHADER = `
  precision mediump float;
  varying vec3 vNormal;
  void main() {
    vec3 lightDir = normalize(vec3(0.4, 0.6, 1.0));
    float diff = max(dot(normalize(vNormal), lightDir), 0.0);
    vec3 base = vec3(0.55, 0.58, 0.64);
    vec3 color = base * (0.35 + 0.65 * diff);
    gl_FragColor = vec4(color, 1.0);
  }
`;

/// Orbit camera (drag to rotate, wheel to zoom) around a mesh centered at
/// its own bounding-box center — mirrors SceneKit's `allowsCameraControl`.
function v3dStart(canvas, mesh) {
  const gl = canvas.getContext("webgl");
  if (!gl) throw new Error("WebGL non disponible dans ce navigateur");

  const program = v3dCreateProgram(gl, V3D_VERTEX_SHADER, V3D_FRAGMENT_SHADER);
  gl.useProgram(program);

  const { positions, normals } = mesh;
  const bounds = v3dBounds(positions);
  const center = [
    (bounds.min[0] + bounds.max[0]) / 2,
    (bounds.min[1] + bounds.max[1]) / 2,
    (bounds.min[2] + bounds.max[2]) / 2,
  ];
  const size = Math.max(
    bounds.max[0] - bounds.min[0],
    bounds.max[1] - bounds.min[1],
    bounds.max[2] - bounds.min[2]
  ) || 1;

  const posBuffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, posBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, positions, gl.STATIC_DRAW);
  const posLoc = gl.getAttribLocation(program, "aPosition");
  gl.enableVertexAttribArray(posLoc);
  gl.vertexAttribPointer(posLoc, 3, gl.FLOAT, false, 0, 0);

  const normBuffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, normBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, normals, gl.STATIC_DRAW);
  const normLoc = gl.getAttribLocation(program, "aNormal");
  gl.enableVertexAttribArray(normLoc);
  gl.vertexAttribPointer(normLoc, 3, gl.FLOAT, false, 0, 0);

  const uModelView = gl.getUniformLocation(program, "uModelView");
  const uProjection = gl.getUniformLocation(program, "uProjection");
  const uNormalMatrix = gl.getUniformLocation(program, "uNormalMatrix");

  gl.enable(gl.DEPTH_TEST);
  gl.clearColor(0.09, 0.09, 0.11, 1);

  let rotX = -0.4, rotY = 0.6, distance = size * 2.2;
  let dragging = false, lastX = 0, lastY = 0;

  function render() {
    v3dResizeCanvas(canvas);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    const aspect = canvas.width / canvas.height || 1;
    const projection = v3dPerspective(Math.PI / 4, aspect, size * 0.01, size * 20);

    let mv = v3dTranslate(v3dIdentity(), 0, 0, -distance);
    mv = v3dRotateX(mv, rotX);
    mv = v3dRotateY(mv, rotY);
    mv = v3dTranslate(mv, -center[0], -center[1], -center[2]);

    gl.uniformMatrix4fv(uModelView, false, mv);
    gl.uniformMatrix4fv(uProjection, false, projection);
    gl.uniformMatrix3fv(uNormalMatrix, false, v3dNormalMatrix(mv));

    gl.drawArrays(gl.TRIANGLES, 0, positions.length / 3);
  }

  canvas.addEventListener("mousedown", (e) => { dragging = true; lastX = e.clientX; lastY = e.clientY; });
  window.addEventListener("mouseup", () => { dragging = false; });
  window.addEventListener("mousemove", (e) => {
    if (!dragging) return;
    rotY += (e.clientX - lastX) * 0.01;
    rotX += (e.clientY - lastY) * 0.01;
    lastX = e.clientX; lastY = e.clientY;
    render();
  });
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    distance *= (1 + e.deltaY * 0.001);
    distance = Math.max(size * 0.3, Math.min(size * 10, distance));
    render();
  }, { passive: false });

  render();
}
