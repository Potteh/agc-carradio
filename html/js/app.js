const radioShell = document.getElementById('radio-shell');
const closeButton = document.getElementById('close-button');
const playPauseButton = document.getElementById('play-pause-button');
const stopButton = document.getElementById('stop-button');
const volumeSlider = document.getElementById('volume-slider');
const volumeValue = document.getElementById('volume-value');
const vehiclePlate = document.getElementById('vehicle-plate');
const occupantRole = document.getElementById('occupant-role');
const trackTitle = document.getElementById('track-title');
const trackSource = document.getElementById('track-source');
const systemStatus = document.getElementById('system-status');
const youtubeForm = document.getElementById('youtube-form');
const streamForm = document.getElementById('stream-form');

let isOpen = false;
let isPlaying = false;

async function postNUI(event, data = {}) {
    try {
        const response = await fetch(`https://${GetParentResourceName()}/${event}`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json; charset=UTF-8'
            },
            body: JSON.stringify(data)
        });

        return await response.json();
    } catch (error) {
        console.error(`[acg_radio] NUI callback "${event}" failed`, error);
        return { ok: false };
    }
}

function updateVolumeDisplay() {
    const value = Number(volumeSlider.value);
    const max = Number(volumeSlider.max) || 100;
    const fill = Math.min((value / max) * 100, 100);

    volumeValue.value = `${value}%`;
    volumeSlider.style.background = `linear-gradient(to right, var(--accent) ${fill}%, rgba(255, 255, 255, 0.12) ${fill}%)`;
}

function setPlaying(playing) {
    isPlaying = playing;
    playPauseButton.classList.toggle('playing', playing);
    playPauseButton.setAttribute('aria-label', playing ? 'Pause' : 'Play');
}

function setStatus(message) {
    systemStatus.textContent = message;
}

function showRadio(payload) {
    const vehicle = payload.vehicle || {};
    const settings = payload.settings || {};

    youtubeForm.reset();
    streamForm.reset();
    selectTab('youtube');
    setPlaying(false);
    trackTitle.textContent = 'No source selected';
    trackSource.textContent = 'Choose a source below to test the controls';

    vehiclePlate.textContent = vehicle.plate || 'VEHICLE';
    occupantRole.textContent = vehicle.isDriver ? 'DRIVER' : 'PASSENGER';

    const maxVolume = Number(settings.maxVolume) || 100;
    const defaultVolume = Math.min(Number(settings.defaultVolume) || 0, maxVolume);
    volumeSlider.max = String(maxVolume);
    volumeSlider.value = String(defaultVolume);
    updateVolumeDisplay();

    radioShell.hidden = false;
    radioShell.setAttribute('aria-hidden', 'false');
    requestAnimationFrame(() => radioShell.classList.add('visible'));
    isOpen = true;
    setStatus('SYSTEM READY');
}

function hideRadio() {
    radioShell.classList.remove('visible');
    radioShell.setAttribute('aria-hidden', 'true');
    radioShell.hidden = true;
    isOpen = false;
}

async function closeRadio() {
    if (!isOpen) {
        return;
    }

    hideRadio();
    await postNUI('close');
}

function selectTab(tabName) {
    document.querySelectorAll('.tab-button').forEach((button) => {
        const selected = button.dataset.tab === tabName;
        button.classList.toggle('active', selected);
        button.setAttribute('aria-selected', String(selected));
    });

    document.querySelectorAll('.tab-panel').forEach((panel) => {
        panel.classList.toggle('active', panel.dataset.panel === tabName);
    });
}

window.addEventListener('message', (event) => {
    const payload = event.data || {};

    if (payload.action === 'openRadio') {
        showRadio(payload);
    } else if (payload.action === 'closeRadio') {
        hideRadio();
    }
});

document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && isOpen) {
        event.preventDefault();
        closeRadio();
    }
});

closeButton.addEventListener('click', closeRadio);

document.querySelectorAll('.tab-button').forEach((button) => {
    button.addEventListener('click', () => selectTab(button.dataset.tab));
});

youtubeForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const url = document.getElementById('youtube-url').value.trim();
    const result = await postNUI('playYoutube', { url });

    if (result.ok) {
        trackTitle.textContent = 'YouTube source selected';
        trackSource.textContent = url;
        setPlaying(true);
        setStatus('REQUEST SENT');
    }
});

streamForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const url = document.getElementById('stream-url').value.trim();
    const stationName = document.getElementById('station-name').value.trim();
    const result = await postNUI('playStream', { url, stationName });

    if (result.ok) {
        trackTitle.textContent = stationName || 'Radio stream selected';
        trackSource.textContent = url;
        setPlaying(true);
        setStatus('REQUEST SENT');
    }
});

playPauseButton.addEventListener('click', async () => {
    const event = isPlaying ? 'pause' : 'resume';
    const result = await postNUI(event);

    if (result.ok) {
        setPlaying(!isPlaying);
        setStatus(event === 'pause' ? 'PAUSE REQUESTED' : 'RESUME REQUESTED');
    }
});

stopButton.addEventListener('click', async () => {
    const result = await postNUI('stop');

    if (result.ok) {
        setPlaying(false);
        trackTitle.textContent = 'No source selected';
        trackSource.textContent = 'Choose a source below to test the controls';
        setStatus('STOP REQUESTED');
    }
});

volumeSlider.addEventListener('input', updateVolumeDisplay);
volumeSlider.addEventListener('change', async () => {
    const result = await postNUI('setVolume', { volume: Number(volumeSlider.value) });

    if (result.ok) {
        setStatus('VOLUME REQUESTED');
    }
});

function initializeUI() {
    hideRadio();
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeUI, { once: true });
} else {
    initializeUI();
}
