(() => {
  "use strict";
  const config = window.APP_CONFIG;
  const $ = (id) => document.getElementById(id);
  const languageSelect = $("language-select");
  let pollHandle = null;
  let latestFiles = [];
  let latestSummaries = [];

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
  }

  function showMessage(message, isError = false) {
    const el = $("global-message");
    el.textContent = message;
    el.classList.remove("hidden");
    if (isError) el.classList.add("error-text"); else el.classList.remove("error-text");
    window.setTimeout(() => el.classList.add("hidden"), 9000);
  }

  function inlineMessage(id, message, type = "info") {
    const el = $(id);
    el.textContent = message;
    el.classList.remove("hidden", "error", "success");
    if (type === "error") el.classList.add("error");
    if (type === "success") el.classList.add("success");
  }

  async function api(path, options = {}) {
    const headers = new Headers(options.headers || {});
    if (options.body && !headers.has("Content-Type")) headers.set("Content-Type", "application/json");
    const response = await fetch(`${config.apiBaseUrl}${path}`, { ...options, headers });
    const text = await response.text();
    let data = {};
    try { data = text ? JSON.parse(text) : {}; } catch { data = { error: text || "Respuesta no válida del servidor." }; }
    if (!response.ok) throw new Error(data.error || `La solicitud falló (${response.status}).`);
    return data;
  }

  function statusLabel(status) {
    return ({ UPLOADING: "Subiendo", TRANSCRIBING: "Transcribiendo", QUEUED: "En cola", PROCESSING: "Generando", COMPLETED: "Completado", FAILED: "Error" })[status] || status || "Desconocido";
  }

  function dateLabel(value) {
    if (!value) return "Fecha no disponible";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return value;
    return new Intl.DateTimeFormat("es-CO", { dateStyle: "medium", timeStyle: "short" }).format(date);
  }

  function bytesLabel(n) {
    if (!n) return "Tamaño no disponible";
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
    return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  }

  function renderFiles() {
    const root = $("files-list");
    if (!latestFiles.length) root.innerHTML = '<div class="empty-state">Todavía no has cargado archivos.</div>';
    else root.innerHTML = latestFiles.map((file) => {
      const viewButton = file.status === "COMPLETED" ? `<button class="small-button" data-action="view-transcript" data-id="${escapeHtml(file.id)}">Ver transcripción</button>` : "";
      const reason = file.failure_reason ? `<div class="file-reason">${escapeHtml(file.failure_reason)}</div>` : "";
      return `<article class="file-card"><div class="file-main"><div class="file-icon">♫</div><div class="file-info"><div class="file-name">${escapeHtml(file.filename)}</div><div class="file-meta">${escapeHtml(bytesLabel(file.size_bytes))} · ${escapeHtml(file.language_code || "Idioma no especificado")} · ${escapeHtml(dateLabel(file.created_at))}</div>${reason}</div></div><div class="file-actions"><span class="status-badge ${escapeHtml(file.status)}">${escapeHtml(statusLabel(file.status))}</span>${viewButton}</div></article>`;
    }).join("");
    const completed = latestFiles.filter((f) => f.status === "COMPLETED").length;
    $("files-subtitle").textContent = `${latestFiles.length} archivo(s) · ${completed} transcripción(es) completada(s).`;
    $("summary-button").disabled = completed === 0;
    $("summary-hint").textContent = completed === 0 ? "Completa al menos una transcripción para habilitar el resumen." : `Se incluirán las ${completed} transcripción(es) completada(s) en el momento de pulsar el botón.`;
  }

  function renderSummaries() {
    const root = $("summaries-list");
    if (!latestSummaries.length) root.innerHTML = '<div class="empty-state">Todavía no has generado resúmenes.</div>';
    else root.innerHTML = latestSummaries.map((item) => {
      const action = item.status === "COMPLETED" ? `<button class="small-button" data-action="download-summary" data-id="${escapeHtml(item.id)}">Descargar .md ↓</button>` : "";
      const reason = item.failure_reason ? `<div class="file-reason">${escapeHtml(item.failure_reason)}</div>` : "";
      return `<article class="file-card"><div class="file-main"><div class="file-icon">▤</div><div class="file-info"><div class="file-name">${escapeHtml(item.filename)}</div><div class="file-meta">${escapeHtml(String(item.file_count))} fuente(s) · ${escapeHtml(dateLabel(item.created_at))}</div>${reason}</div></div><div class="file-actions"><span class="status-badge ${escapeHtml(item.status)}">${escapeHtml(statusLabel(item.status))}</span>${action}</div></article>`;
    }).join("");
  }

  async function loadFiles() {
    const data = await api("/transcripts");
    latestFiles = data.items || [];
    renderFiles();
  }

  async function loadSummaries() {
    const data = await api("/summaries");
    latestSummaries = data.items || [];
    renderSummaries();
  }

  async function refreshAll() {
    await Promise.all([loadFiles(), loadSummaries()]);
    const busy = latestFiles.some((f) => ["UPLOADING", "TRANSCRIBING", "QUEUED"].includes(f.status)) || latestSummaries.some((s) => ["QUEUED", "PROCESSING"].includes(s.status));
    if (!busy && pollHandle) { clearInterval(pollHandle); pollHandle = null; }
    if (busy && !pollHandle) pollHandle = window.setInterval(() => refreshAll().catch((err) => console.warn(err)), 5000);
  }

  async function uploadFile(file) {
    const extension = file.name.split(".").pop().toLowerCase();
    const mimeByExtension = { mp3: "audio/mpeg", mp4: "audio/mp4", wav: "audio/wav", flac: "audio/flac", ogg: "audio/ogg", amr: "audio/amr", webm: "audio/webm", m4a: "audio/mp4" };
    const contentType = file.type || mimeByExtension[extension] || "application/octet-stream";
    const created = await api("/uploads", {
      method: "POST",
      body: JSON.stringify({ filename: file.name, content_type: contentType, size_bytes: file.size, language_code: languageSelect.value })
    });
    const formData = new FormData();
    Object.entries(created.upload_fields || {}).forEach(([key, value]) => formData.append(key, value));
    formData.append("file", file);
    const uploadResponse = await fetch(created.upload_url, { method: "POST", body: formData });
    if (!uploadResponse.ok) throw new Error(`No se pudo subir ${file.name} a S3 (${uploadResponse.status}). Comprueba la configuración CORS del bucket y vuelve a intentarlo.`);
  }

  async function onUpload(event) {
    event.preventDefault();
    const files = Array.from($("audio-files").files || []);
    if (!files.length) return;
    const button = $("upload-button");
    button.disabled = true;
    try {
      for (let index = 0; index < files.length; index += 1) {
        inlineMessage("upload-progress", `Subiendo ${index + 1} de ${files.length}: ${files[index].name}`);
        await uploadFile(files[index]);
      }
      inlineMessage("upload-progress", `${files.length} archivo(s) cargado(s). La transcripción se iniciará automáticamente.`, "success");
      $("audio-files").value = "";
      await refreshAll();
      if (!pollHandle) pollHandle = window.setInterval(() => refreshAll().catch((err) => console.warn(err)), 5000);
    } catch (error) {
      inlineMessage("upload-progress", error.message || "Error durante la carga.", "error");
    } finally {
      button.disabled = false;
    }
  }

  async function generateSummary() {
    const button = $("summary-button");
    button.disabled = true;
    try {
      inlineMessage("summary-progress", "Registrando el trabajo de resumen…");
      const result = await api("/summaries", { method: "POST", body: JSON.stringify({}) });
      inlineMessage("summary-progress", `Resumen en cola (${result.file_count} transcripción(es)). Se actualizará su estado automáticamente.`, "success");
      await loadSummaries();
      if (!pollHandle) pollHandle = window.setInterval(() => refreshAll().catch((err) => console.warn(err)), 5000);
    } catch (error) {
      inlineMessage("summary-progress", error.message || "No se pudo iniciar el resumen.", "error");
    } finally {
      button.disabled = latestFiles.filter((f) => f.status === "COMPLETED").length === 0;
    }
  }

  async function viewTranscript(id) {
    try {
      const data = await api(`/transcripts/${encodeURIComponent(id)}`);
      $("dialog-title").textContent = data.filename || "Transcripción";
      $("dialog-content").textContent = data.transcript || "La transcripción está vacía.";
      $("transcript-dialog").showModal();
    } catch (error) { showMessage(error.message || "No se pudo cargar la transcripción.", true); }
  }

  async function downloadSummary(id) {
    try {
      const data = await api(`/summaries/${encodeURIComponent(id)}`);
      if (data.status !== "COMPLETED" || !data.download_url) {
        showMessage(`El resumen está ${statusLabel(data.status).toLowerCase()}.`);
        await loadSummaries();
        return;
      }
      window.location.assign(data.download_url);
    } catch (error) { showMessage(error.message || "No se pudo descargar el resumen.", true); }
  }

  async function initialize() {
    if (!config || !config.apiBaseUrl) {
      showMessage("Falta la configuración generada por Terraform (config.js).", true);
      return;
    }
    try {
      await refreshAll();
      if (latestFiles.some((f) => ["UPLOADING", "TRANSCRIBING", "QUEUED"].includes(f.status)) || latestSummaries.some((s) => ["QUEUED", "PROCESSING"].includes(s.status))) {
        if (!pollHandle) pollHandle = window.setInterval(() => refreshAll().catch((err) => console.warn(err)), 5000);
      }
    } catch (error) {
      showMessage(error.message || "No se pudo inicializar la aplicación.", true);
    }
  }

  $("upload-form").addEventListener("submit", onUpload);
  $("summary-button").addEventListener("click", generateSummary);
  $("refresh-button").addEventListener("click", () => refreshAll().catch((err) => showMessage(err.message, true)));
  $("close-dialog").addEventListener("click", () => $("transcript-dialog").close());
  $("files-list").addEventListener("click", (event) => {
    const target = event.target.closest("button[data-action]");
    if (!target) return;
    if (target.dataset.action === "view-transcript") viewTranscript(target.dataset.id);
  });
  $("summaries-list").addEventListener("click", (event) => {
    const target = event.target.closest("button[data-action]");
    if (target && target.dataset.action === "download-summary") downloadSummary(target.dataset.id);
  });

  initialize();
})();
