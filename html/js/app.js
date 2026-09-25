const radioShell = document.getElementById('radio-shell');
const closeButton = document.getElementById('close-button');
const radioPanel = document.getElementById('radio-panel');
const radioHeader = document.querySelector('.radio-header');
const windowResizeHandle = document.getElementById('window-resize-handle');
const resetWindowButton = document.getElementById('reset-window-button');
const playPauseButton = document.getElementById('play-pause-button');
const stopButton = document.getElementById('stop-button');
const skipButton = document.getElementById('skip-button');
const favoriteButton = document.getElementById('favorite-button');
const favoritesList = document.getElementById('favorites-list');
const favoritesCount = document.getElementById('favorites-count');
const historyList = document.getElementById('history-list');
const clearHistoryButton = document.getElementById('clear-history-button');
const queueAddButton = document.getElementById('queue-add-button');
const queueList = document.getElementById('queue-list');
const queueCount = document.getElementById('queue-count');
const queueSection = document.getElementById('queue-section');
const trackThumbnail = document.getElementById('track-thumbnail');
const coverPlaceholder = document.getElementById('cover-placeholder');
const volumeSlider = document.getElementById('volume-slider');
const volumeValue = document.getElementById('volume-value');
const playbackSlider = document.getElementById('playback-slider');
const playbackTime = document.getElementById('playback-time');
const playbackProgress = document.querySelector('.playback-progress');
const vehiclePlate = document.getElementById('vehicle-plate');
const occupantRole = document.getElementById('occupant-role');
const streamerModeIndicator = document.getElementById('streamer-mode-indicator');
const trackTitle = document.getElementById('track-title');
const trackSource = document.getElementById('track-source');
const systemStatus = document.getElementById('system-status');
const youtubeForm = document.getElementById('youtube-form');
const youtubePlayButton = youtubeForm.querySelector('button[type="submit"]');
const streamForm = document.getElementById('stream-form');
const stationList = document.getElementById('station-list');
const customStreamSection = document.getElementById('custom-stream-section');
const streamPlayer = new Audio();
const entertainmentForm = document.getElementById('entertainment-form');
const entertainmentInput = document.getElementById('entertainment-input');
const entertainmentInputLabel = document.getElementById('entertainment-input-label');
const entertainmentScreen = document.getElementById('entertainment-screen');
const entertainmentPlaceholder = document.getElementById('entertainment-placeholder');
const entertainmentStopButton = document.getElementById('entertainment-stop');
const entertainmentServiceBadge = document.getElementById('entertainment-service-badge');

const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/;

let isOpen = false;
let canControl = false;
let isSeeking = false;
let autoplayBlocked = false;
let youtubePlayer = null;
let metadataPlayer = null;
let metadataPlayerReady = false;
let metadataRequest = null;
let youtubePlayerReady = false;
let youtubeApiRequested = false;
let youtubeApiAttempts = 0;
let youtubeRetryTimer = null;
let youtubeReadyTimeout = null;
let loadedVideoId = null;
let provisionalVideoId = null;
let provisionalCleanupTimer = null;
let currentTitle = '';
let currentAuthor = '';
let lastMetadataVideoId = null;
let pendingRadioState = null;
let activeRadioState = null;
let activeMediaSource = 'none';
let loadedStreamUrl = null;
let streamPlaybackStatus = 'idle';
let streamPlaybackBlocked = false;
let streamErrorNotified = false;
let streamPlayAttempt = 0;
let localEffectiveVolume = 0;
let currentEffectiveVolume = 0;
let targetEffectiveVolume = 0;
let lastAppliedMediaVolume = -1;
let streamerMode = false;
let entertainmentService = 'youtube';
let entertainmentActive = false;
let entertainmentTarget = null;
let debugEnabled = false;
let maxVolume = 100;
let driftTimer = null;
// Prevent the ended YouTube video from being restarted by a stale synchronized
// state while the server is advancing the queue or removing the finished radio.
let endedYouTubeGuard = null;
let displayTimer = null;
let volumeSmoothingTimer = null;
let statusLockedUntil = 0;
let statusIsError = false;
let syncSettings = {
    DriftCheckInterval: 5000,
    DriftThreshold: 2.5
};
let queueSettings = { enabled: true, maxItems: 20 };
let librarySettings = { favoritesMaxItems: 50, historyMaxItems: 25 };
let favorites = [];
let recentHistory = [];
let lastHistoryVideoId = null;
const FAVORITES_STORAGE_KEY = 'acg_radio_favorites_v1';
const HISTORY_STORAGE_KEY = 'acg_radio_history_v1';
const WINDOW_STORAGE_KEY = 'agc_carradio_window_v1';
const WINDOW_MARGIN = 12;
const WINDOW_MIN_WIDTH = 520;
const WINDOW_MIN_HEIGHT = 420;
let windowGeometry = null;
let windowPointerMode = null;
let windowPointerStart = null;

function clampWindowGeometry(geometry) {
    const vw = Math.max(document.documentElement.clientWidth || 0, window.innerWidth || 0);
    const vh = Math.max(document.documentElement.clientHeight || 0, window.innerHeight || 0);
    const minWidth = Math.min(WINDOW_MIN_WIDTH, Math.max(320, vw - WINDOW_MARGIN * 2));
    const minHeight = Math.min(WINDOW_MIN_HEIGHT, Math.max(300, vh - WINDOW_MARGIN * 2));
    const width = clamp(Number(geometry.width) || 760, minWidth, Math.max(minWidth, vw - WINDOW_MARGIN * 2));
    const height = clamp(Number(geometry.height) || Math.min(760, vh - 48), minHeight, Math.max(minHeight, vh - WINDOW_MARGIN * 2));
    const x = clamp(Number(geometry.x) || WINDOW_MARGIN, WINDOW_MARGIN, Math.max(WINDOW_MARGIN, vw - width - WINDOW_MARGIN));
    const y = clamp(Number(geometry.y) || WINDOW_MARGIN, WINDOW_MARGIN, Math.max(WINDOW_MARGIN, vh - height - WINDOW_MARGIN));
    return { x, y, width, height };
}

function defaultWindowGeometry() {
    const vw = Math.max(document.documentElement.clientWidth || 0, window.innerWidth || 0);
    const vh = Math.max(document.documentElement.clientHeight || 0, window.innerHeight || 0);
    const width = Math.min(760, Math.max(520, vw - 48));
    const height = Math.min(760, Math.max(520, vh - 80));
    return clampWindowGeometry({ x: (vw - width) / 2, y: (vh - height) / 2, width, height });
}

function loadWindowGeometry() {
    try {
        const saved = JSON.parse(localStorage.getItem(WINDOW_STORAGE_KEY) || 'null');
        if (saved && typeof saved === 'object') return clampWindowGeometry(saved);
    } catch (_) {}
    return defaultWindowGeometry();
}

function applyWindowGeometry(save = false) {
    if (!radioPanel) return;
    windowGeometry = clampWindowGeometry(windowGeometry || loadWindowGeometry());
    radioPanel.classList.add('window-managed');
    radioPanel.style.left = `${windowGeometry.x}px`;
    radioPanel.style.top = `${windowGeometry.y}px`;
    radioPanel.style.width = `${windowGeometry.width}px`;
    radioPanel.style.height = `${windowGeometry.height}px`;
    if (save) {
        try { localStorage.setItem(WINDOW_STORAGE_KEY, JSON.stringify(windowGeometry)); } catch (_) {}
    }
}

function resetWindowGeometry() {
    windowGeometry = defaultWindowGeometry();
    applyWindowGeometry(true);
}

function beginWindowPointer(event, mode) {
    if (!isOpen || event.button !== 0) return;
    if (mode === 'drag' && event.target.closest('button, input, select, textarea, a')) return;
    event.preventDefault();
    windowPointerMode = mode;
    windowPointerStart = { x: event.clientX, y: event.clientY, geometry: { ...windowGeometry } };
    window.addEventListener('pointermove', handleWindowPointerMove);
    window.addEventListener('pointerup', endWindowPointer, { once: true });
}

function handleWindowPointerMove(event) {
    if (!windowPointerMode || !windowPointerStart) return;
    const dx = event.clientX - windowPointerStart.x;
    const dy = event.clientY - windowPointerStart.y;
    const base = windowPointerStart.geometry;
    if (windowPointerMode === 'drag') {
        windowGeometry = { ...base, x: base.x + dx, y: base.y + dy };
    } else {
        windowGeometry = { ...base, width: base.width + dx, height: base.height + dy };
    }
    applyWindowGeometry(false);
}

function endWindowPointer() {
    window.removeEventListener('pointermove', handleWindowPointerMove);
    windowPointerMode = null;
    windowPointerStart = null;
    applyWindowGeometry(true);
}

let streamSettings = {
    allowCustomUrls: false,
    maxUrlLength: 2048,
    stations: []
};

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

function debugYouTube(message) {
    if (!debugEnabled) {
        return;
    }

    console.log(`[acg_radio] ${message}`);
    postNUI('youtubeDebug', { message });
}

function debugStream(message) {
    if (!debugEnabled) {
        return;
    }

    console.log(`[acg_radio] ${message}`);
    postNUI('streamDebug', { message });
}

function getYouTubeStateName(state) {
    if (!window.YT || !window.YT.PlayerState) {
        return `UNKNOWN (${state})`;
    }

    const states = window.YT.PlayerState;
    if (state === states.UNSTARTED) return 'UNSTARTED';
    if (state === states.ENDED) return 'ENDED';
    if (state === states.PLAYING) return 'PLAYING';
    if (state === states.PAUSED) return 'PAUSED';
    if (state === states.BUFFERING) return 'BUFFERING';
    if (state === states.CUED) return 'CUED';
    return `UNKNOWN (${state})`;
}

function debugYouTubeSnapshot(context, requestedPosition = null) {
    if (!debugEnabled) {
        return;
    }

    if (!youtubePlayerReady || !youtubePlayer) {
        debugYouTube(`${context} ready=false window.YT=${Boolean(window.YT)} YT.Player=${Boolean(window.YT && window.YT.Player)}`);
        return;
    }

    const videoData = youtubePlayer.getVideoData ? youtubePlayer.getVideoData() : {};
    const state = youtubePlayer.getPlayerState();
    const requested = requestedPosition === null ? 'n/a' : Number(requestedPosition).toFixed(1);
    debugYouTube(
        `${context} videoId=${videoData.video_id || loadedVideoId || 'none'} ready=true state=${getYouTubeStateName(state)}`
        + ` muted=${youtubePlayer.isMuted()} volume=${youtubePlayer.getVolume()}`
        + ` current=${(Number(youtubePlayer.getCurrentTime()) || 0).toFixed(1)} requested=${requested}`
    );
}

function clamp(value, minimum, maximum) {
    return Math.max(minimum, Math.min(maximum, value));
}

function isValidNumber(value) {
    return typeof value === 'number' && Number.isFinite(value);
}

function formatTime(value) {
    const totalSeconds = Math.max(0, Math.floor(Number(value) || 0));
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;

    if (hours > 0) {
        return `${hours}:${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
    }

    return `${minutes}:${String(seconds).padStart(2, '0')}`;
}

function setRangeFill(input, value, maximum) {
    const fill = maximum > 0 ? clamp((value / maximum) * 100, 0, 100) : 0;
    input.style.background = `linear-gradient(to right, var(--accent) ${fill}%, rgba(255, 255, 255, 0.12) ${fill}%)`;
}

function updateVolumeDisplay() {
    const value = Number(volumeSlider.value);
    const maximum = Number(volumeSlider.max) || 100;

    volumeValue.value = `${value}%`;
    setRangeFill(volumeSlider, value, maximum);
}

function setPlaying(playing) {
    playPauseButton.classList.toggle('playing', playing);
    playPauseButton.setAttribute('aria-label', playing ? 'Pause' : 'Resume');
}

function setStatus(message, isError = false, holdMilliseconds = 0) {
    systemStatus.textContent = message;
    systemStatus.style.color = isError ? 'var(--danger)' : 'var(--accent)';
    statusIsError = isError;
    statusLockedUntil = holdMilliseconds > 0 ? Date.now() + holdMilliseconds : 0;
}

function setPlaybackStatus(message) {
    if (Date.now() < statusLockedUntil) {
        return;
    }

    setStatus(message);
}

function setControlPermission(isDriver, driverOnly) {
    canControl = !driverOnly || isDriver;
    occupantRole.textContent = isDriver ? 'DRIVER' : 'PASSENGER';

    youtubeForm.querySelectorAll('input, button').forEach((control) => {
        control.disabled = !canControl;
    });
    streamForm.querySelectorAll('input, button').forEach((control) => {
        control.disabled = !canControl;
    });
    playPauseButton.disabled = !canControl && !autoplayBlocked;
    stopButton.disabled = !canControl;
    skipButton.disabled = !canControl || !activeRadioState || activeRadioState.source !== 'youtube';
    queueAddButton.disabled = !canControl || !queueSettings.enabled;
    volumeSlider.disabled = !canControl;
    youtubePlayButton.disabled = !canControl || !youtubePlayerReady;
    updatePlaybackDisplay();
    renderLibrary();
}

function applySettings(settings = {}) {
    if (isValidNumber(Number(settings.maxVolume))) {
        maxVolume = clamp(Number(settings.maxVolume), 1, 100);
        volumeSlider.max = String(maxVolume);
    }

    if (settings.queue && typeof settings.queue === 'object') {
        queueSettings = {
            enabled: settings.queue.enabled === true,
            maxItems: Math.max(Number(settings.queue.maxItems) || 20, 1)
        };
        queueSection.hidden = !queueSettings.enabled;
    }

    if (settings.library && typeof settings.library === 'object') {
        librarySettings = {
            favoritesMaxItems: Math.max(Number(settings.library.favoritesMaxItems) || 50, 1),
            historyMaxItems: Math.max(Number(settings.library.historyMaxItems) || 25, 1)
        };
        loadLibrary();
    }

    if (settings.streams && typeof settings.streams === 'object') {
        streamSettings = {
            allowCustomUrls: settings.streams.allowCustomUrls === true,
            maxUrlLength: Math.max(Number(settings.streams.maxUrlLength) || 2048, 1),
            stations: Array.isArray(settings.streams.stations) ? settings.streams.stations : []
        };
        renderStationList();
        customStreamSection.hidden = !streamSettings.allowCustomUrls;
    }

    if (settings.sync && typeof settings.sync === 'object') {
        const interval = Number(settings.sync.DriftCheckInterval);
        const threshold = Number(settings.sync.DriftThreshold);

        if (Number.isFinite(interval) && interval >= 1000) {
            syncSettings.DriftCheckInterval = interval;
        }
        if (Number.isFinite(threshold) && threshold > 0) {
            syncSettings.DriftThreshold = threshold;
        }
    }

    debugEnabled = settings.debug === true;
    setStreamerMode(settings.streamerMode === true);
    restartDriftTimer();
}

function renderStationList() {
    stationList.replaceChildren();

    if (streamSettings.stations.length === 0) {
        const empty = document.createElement('p');
        empty.className = 'station-empty';
        empty.textContent = 'No preset stations configured';
        stationList.appendChild(empty);
        return;
    }

    streamSettings.stations.forEach((station) => {
        if (!station || typeof station.id !== 'string' || typeof station.name !== 'string') {
            return;
        }

        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'station-card';
        button.disabled = !canControl;
        button.dataset.stationId = station.id;

        const copy = document.createElement('span');
        copy.className = 'station-copy';
        const name = document.createElement('span');
        name.className = 'station-name';
        name.textContent = station.name;
        const genre = document.createElement('span');
        genre.className = 'station-genre';
        genre.textContent = typeof station.genre === 'string' ? station.genre : 'Radio';
        const action = document.createElement('span');
        action.className = 'station-action';
        action.textContent = 'PLAY';

        copy.append(name, genre);
        button.append(copy, action);
        button.addEventListener('click', () => requestConfiguredStation(station.id));
        stationList.appendChild(button);
    });
}

function safeStoredTracks(key, maxItems) {
    try {
        const parsed = JSON.parse(localStorage.getItem(key) || '[]');
        if (!Array.isArray(parsed)) return [];
        return parsed.filter((item) => item && VIDEO_ID_PATTERN.test(item.videoId || ''))
            .slice(0, maxItems)
            .map((item) => ({
                videoId: item.videoId,
                title: typeof item.title === 'string' ? item.title.slice(0, 120) : '',
                author: typeof item.author === 'string' ? item.author.slice(0, 80) : '',
                duration: Math.max(0, Number(item.duration) || 0)
            }));
    } catch (_) {
        return [];
    }
}

function loadLibrary() {
    favorites = safeStoredTracks(FAVORITES_STORAGE_KEY, librarySettings.favoritesMaxItems);
    recentHistory = safeStoredTracks(HISTORY_STORAGE_KEY, librarySettings.historyMaxItems);
    renderLibrary();
}

function persistLibrary() {
    try {
        localStorage.setItem(FAVORITES_STORAGE_KEY, JSON.stringify(favorites.slice(0, librarySettings.favoritesMaxItems)));
        localStorage.setItem(HISTORY_STORAGE_KEY, JSON.stringify(recentHistory.slice(0, librarySettings.historyMaxItems)));
    } catch (error) {
        if (debugEnabled) console.warn('[acg_radio] Unable to persist local library', error);
    }
}

function trackFromState(state = activeRadioState) {
    if (!state || state.source !== 'youtube' || !VIDEO_ID_PATTERN.test(state.videoId || '')) return null;
    return {
        videoId: state.videoId,
        title: currentTitle || state.title || '',
        author: currentAuthor || state.author || '',
        duration: Math.max(0, Number(state.duration) || 0)
    };
}

function recordRecentTrack(state = activeRadioState) {
    const track = trackFromState(state);
    if (!track || track.videoId === lastHistoryVideoId) return;
    lastHistoryVideoId = track.videoId;
    recentHistory = [track, ...recentHistory.filter((item) => item.videoId !== track.videoId)]
        .slice(0, librarySettings.historyMaxItems);
    persistLibrary();
    renderLibrary();
}

function toggleFavoriteCurrent() {
    const track = trackFromState();
    if (!track) return;
    const index = favorites.findIndex((item) => item.videoId === track.videoId);
    if (index >= 0) {
        favorites.splice(index, 1);
        setStatus('REMOVED FROM FAVORITES', false, 2500);
    } else {
        favorites = [track, ...favorites.filter((item) => item.videoId !== track.videoId)]
            .slice(0, librarySettings.favoritesMaxItems);
        setStatus('ADDED TO FAVORITES', false, 2500);
    }
    persistLibrary();
    renderLibrary();
}

function createLibraryRow(item, isFavorite) {
    const row = document.createElement('div');
    row.className = 'library-item';
    const img = document.createElement('img');
    img.className = 'library-thumb';
    img.alt = '';
    img.src = `https://i.ytimg.com/vi/${item.videoId}/mqdefault.jpg`;
    const copy = document.createElement('span');
    copy.className = 'queue-copy';
    const title = document.createElement('span');
    title.className = 'queue-title';
    title.textContent = item.title || item.videoId;
    const author = document.createElement('span');
    author.className = 'queue-author';
    author.textContent = item.author || 'YouTube';
    copy.append(title, author);
    const actions = document.createElement('span');
    actions.className = 'library-actions';
    const play = document.createElement('button');
    play.type = 'button'; play.className = 'mini-button'; play.textContent = 'PLAY'; play.disabled = !canControl;
    play.addEventListener('click', async () => {
        const result = await postNUI('playYoutube', { videoId: item.videoId });
        if (result.ok) setStatus('WAITING FOR SERVER', false, 2500);
    });
    const queue = document.createElement('button');
    queue.type = 'button'; queue.className = 'mini-button'; queue.textContent = '+ QUEUE'; queue.disabled = !canControl || !queueSettings.enabled;
    queue.addEventListener('click', async () => {
        const result = await postNUI('addToQueue', item);
        if (result.ok) setStatus('ADDED TO QUEUE', false, 2500);
    });
    actions.append(play, queue);
    if (isFavorite) {
        const remove = document.createElement('button');
        remove.type = 'button'; remove.className = 'mini-button'; remove.textContent = 'REMOVE';
        remove.addEventListener('click', () => {
            favorites = favorites.filter((track) => track.videoId !== item.videoId);
            persistLibrary(); renderLibrary();
        });
        actions.append(remove);
    }
    row.append(img, copy, actions);
    return row;
}

function renderLibrary() {
    if (!favoritesList || !historyList) return;
    favoritesList.replaceChildren();
    favoritesCount.textContent = String(favorites.length);
    if (!favorites.length) {
        const empty = document.createElement('p'); empty.className = 'queue-empty'; empty.textContent = 'No favorites yet'; favoritesList.appendChild(empty);
    } else favorites.forEach((item) => favoritesList.appendChild(createLibraryRow(item, true)));
    historyList.replaceChildren();
    if (!recentHistory.length) {
        const empty = document.createElement('p'); empty.className = 'queue-empty'; empty.textContent = 'No recent tracks'; historyList.appendChild(empty);
    } else recentHistory.forEach((item) => historyList.appendChild(createLibraryRow(item, false)));
    const currentId = activeRadioState && activeRadioState.source === 'youtube' ? activeRadioState.videoId : null;
    const favored = currentId && favorites.some((item) => item.videoId === currentId);
    if (favoriteButton) {
        favoriteButton.classList.toggle('active', Boolean(favored));
        favoriteButton.disabled = !currentId;
        favoriteButton.title = favored ? 'Remove from favorites' : 'Add to favorites';
    }
}

function initializeMetadataPlayer() {
    if (metadataPlayer || !window.YT || !window.YT.Player) return;
    metadataPlayer = new window.YT.Player('youtube-metadata-host', {
        width: '200', height: '200',
        playerVars: { autoplay: 0, controls: 0, disablekb: 1, playsinline: 1 },
        events: {
            onReady: () => { metadataPlayerReady = true; },
            onStateChange: () => {
                if (!metadataRequest || !metadataPlayerReady) return;
                const data = metadataPlayer.getVideoData ? metadataPlayer.getVideoData() : {};
                if (data && data.video_id === metadataRequest.videoId && (data.title || data.author)) {
                    const resolve = metadataRequest.resolve;
                    const videoId = metadataRequest.videoId;
                    metadataRequest = null;
                    resolve({ videoId, title: data.title || '', author: data.author || '', duration: Number(metadataPlayer.getDuration ? metadataPlayer.getDuration() : 0) || 0 });
                }
            },
            onError: () => {
                if (metadataRequest) { const resolve = metadataRequest.resolve; const videoId = metadataRequest.videoId; metadataRequest = null; resolve({ videoId }); }
            }
        }
    });
}

function resolveYouTubeMetadata(videoId) {
    return new Promise((resolve) => {
        if (!VIDEO_ID_PATTERN.test(videoId || '') || !metadataPlayerReady || !metadataPlayer) { resolve({ videoId }); return; }
        if (metadataRequest) { metadataRequest.resolve({ videoId: metadataRequest.videoId }); metadataRequest = null; }
        const timer = setTimeout(() => {
            if (metadataRequest && metadataRequest.videoId === videoId) { metadataRequest = null; resolve({ videoId }); }
        }, 4500);
        metadataRequest = { videoId, resolve: (data) => { clearTimeout(timer); resolve(data); } };
        try { metadataPlayer.cueVideoById(videoId); } catch (_) { clearTimeout(timer); metadataRequest = null; resolve({ videoId }); }
    });
}

function renderQueue() {
    const queue = activeRadioState && Array.isArray(activeRadioState.queue)
        ? activeRadioState.queue
        : [];

    queueList.replaceChildren();
    queueCount.textContent = `${queue.length} ${queue.length === 1 ? 'TRACK' : 'TRACKS'}`;

    if (queue.length === 0) {
        const empty = document.createElement('p');
        empty.className = 'queue-empty';
        empty.textContent = 'Queue is empty';
        queueList.appendChild(empty);
    } else {
        queue.forEach((item, index) => {
            const row = document.createElement('div');
            row.className = 'queue-item';

            const number = document.createElement('span');
            number.className = 'queue-number';
            number.textContent = String(index + 1).padStart(2, '0');

            const thumb = document.createElement('img');
            thumb.className = 'queue-thumb';
            thumb.alt = '';
            thumb.src = `https://i.ytimg.com/vi/${item.videoId}/mqdefault.jpg`;

            const copy = document.createElement('span');
            copy.className = 'queue-copy';
            const title = document.createElement('span');
            title.className = 'queue-title';
            title.textContent = item && item.title ? item.title : (item && item.videoId ? item.videoId : 'YouTube track');
            const author = document.createElement('span');
            author.className = 'queue-author';
            author.textContent = item && item.author ? item.author : 'YouTube';
            if (item && Number(item.duration) > 0) author.textContent += ` · ${formatTime(Number(item.duration))}`;
            copy.append(title, author);

            const remove = document.createElement('button');
            remove.type = 'button';
            remove.className = 'queue-remove';
            remove.textContent = '×';
            remove.setAttribute('aria-label', `Remove ${title.textContent} from queue`);
            remove.disabled = !canControl;
            remove.addEventListener('click', async () => {
                const result = await postNUI('removeQueueItem', { index: index + 1 });
                if (result.ok) setStatus('WAITING FOR SERVER', false, 3000);
            });

            row.append(number, thumb, copy, remove);
            queueList.appendChild(row);
        });
    }

    skipButton.disabled = !canControl
        || !activeRadioState
        || activeRadioState.source !== 'youtube';
}

function updateArtwork() {
    const videoId = activeRadioState && activeRadioState.source === 'youtube'
        ? activeRadioState.videoId
        : null;

    if (VIDEO_ID_PATTERN.test(videoId || '')) {
        trackThumbnail.src = `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`;
        trackThumbnail.hidden = false;
        coverPlaceholder.hidden = true;
    } else {
        trackThumbnail.removeAttribute('src');
        trackThumbnail.hidden = true;
        coverPlaceholder.hidden = false;
    }
}

function setStreamerMode(enabled, restoreVolume = null) {
    streamerMode = enabled === true;
    streamerModeIndicator.hidden = !streamerMode;

    if (!streamerMode && Number.isFinite(Number(restoreVolume))) {
        localEffectiveVolume = clamp(Number(restoreVolume), 0, 100);
        if (activeRadioState) {
            activeRadioState.localVolume = localEffectiveVolume;
        }
    }

    setMediaVolume(localEffectiveVolume);
    applySmoothedMediaVolume(true);

    if (entertainmentActive && entertainmentTarget) {
        loadEntertainment(entertainmentService, entertainmentTarget, true);
    }
}

function showRadio(payload) {
    const vehicle = payload.vehicle || {};
    const settings = payload.settings || {};

    applySettings(settings);
    initializeYouTubePlayer();
    youtubeForm.reset();
    streamForm.reset();
    selectTab('youtube');
    vehiclePlate.textContent = vehicle.plate || 'VEHICLE';
    setControlPermission(vehicle.isDriver === true, settings.driverOnly === true);

    if (!activeRadioState) {
        volumeSlider.value = String(clamp(Number(settings.defaultVolume) || 0, 0, maxVolume));
        updateVolumeDisplay();
    }

    windowGeometry = loadWindowGeometry();
    applyWindowGeometry(false);
    radioShell.hidden = false;
    radioShell.setAttribute('aria-hidden', 'false');
    requestAnimationFrame(() => radioShell.classList.add('visible'));
    isOpen = true;
    renderNowPlaying();

    if (!youtubePlayerReady && (!activeRadioState || activeRadioState.source === 'youtube')) {
        setStatus('LOADING YOUTUBE PLAYER', false, 10000);
    }
}

function hideRadio() {
    stopEntertainment();
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

function extractYouTubeVideoId(value) {
    if (typeof value !== 'string' || value.length > 2048) {
        return null;
    }

    try {
        const url = new URL(value.trim());
        const hostname = url.hostname.toLowerCase().replace(/^www\./, '');
        let videoId = null;

        if (hostname === 'youtu.be') {
            videoId = url.pathname.split('/').filter(Boolean)[0] || null;
        } else if (
            hostname === 'youtube.com'
            || hostname === 'm.youtube.com'
            || hostname === 'music.youtube.com'
            || hostname === 'youtube-nocookie.com'
        ) {
            const pathParts = url.pathname.split('/').filter(Boolean);

            if (pathParts[0] === 'watch') {
                videoId = url.searchParams.get('v');
            } else if (
                pathParts[0] === 'shorts'
                || pathParts[0] === 'embed'
                || pathParts[0] === 'live'
                || pathParts[0] === 'v'
            ) {
                videoId = pathParts[1] || null;
            }
        }

        return VIDEO_ID_PATTERN.test(videoId || '') ? videoId : null;
    } catch (_) {
        return null;
    }
}

function isValidStreamUrl(value) {
    if (typeof value !== 'string' || value.length < 1 || value.length > streamSettings.maxUrlLength) {
        return false;
    }

    try {
        const url = new URL(value);
        return url.protocol === 'http:' || url.protocol === 'https:';
    } catch (_) {
        return false;
    }
}

function setEntertainmentService(service) {
    if (!['youtube', 'kick', 'tiktok'].includes(service)) return;
    entertainmentService = service;
    document.querySelectorAll('.entertainment-service').forEach((button) => {
        button.classList.toggle('active', button.dataset.service === service);
    });

    const labels = {
        youtube: ['YouTube video URL', 'https://www.youtube.com/watch?v=...'],
        kick: ['Kick channel or URL', 'kick.com/channelname'],
        tiktok: ['TikTok video URL', 'https://www.tiktok.com/@creator/video/123456789...']
    };
    entertainmentInputLabel.textContent = labels[service][0];
    entertainmentInput.placeholder = labels[service][1];
    entertainmentServiceBadge.textContent = service.toUpperCase();
}

function extractChannelName(value, service) {
    if (typeof value !== 'string') return null;
    const trimmed = value.trim();
    if (/^[A-Za-z0-9_\-]{2,64}$/.test(trimmed)) return trimmed;
    try {
        const url = new URL(trimmed.startsWith('http') ? trimmed : `https://${trimmed}`);
        const host = url.hostname.toLowerCase().replace(/^www\./, '');
        if (service !== 'kick' || host !== 'kick.com') return null;
        const channel = url.pathname.split('/').filter(Boolean)[0] || '';
        return /^[A-Za-z0-9_\-]{2,64}$/.test(channel) ? channel : null;
    } catch (_) {
        return null;
    }
}


function extractTikTokPostId(value) {
    if (typeof value !== 'string') return null;
    const trimmed = value.trim();
    if (/^\d{10,24}$/.test(trimmed)) return trimmed;
    try {
        const url = new URL(trimmed.startsWith('http') ? trimmed : `https://${trimmed}`);
        const host = url.hostname.toLowerCase().replace(/^www\./, '');
        if (host !== 'tiktok.com' && host !== 'm.tiktok.com') return null;
        const match = url.pathname.match(/\/video\/(\d{10,24})(?:\/|$)/);
        return match ? match[1] : null;
    } catch (_) {
        return null;
    }
}

function buildEntertainmentUrl(service, target) {
    const muted = streamerMode ? 'true' : 'false';
    if (service === 'youtube') {
        const videoId = extractYouTubeVideoId(target);
        if (!videoId) return null;
        return `https://www.youtube.com/embed/${encodeURIComponent(videoId)}?autoplay=1&controls=1&playsinline=1`;
    }
    if (service === 'kick') {
        const channel = extractChannelName(target, 'kick');
        if (!channel) return null;
        return `https://player.kick.com/${encodeURIComponent(channel)}?autoplay=true&muted=${muted}`;
    }
    if (service === 'tiktok') {
        const postId = extractTikTokPostId(target);
        if (!postId) return null;
        const mutedFlag = streamerMode ? '1' : '0';
        return `https://www.tiktok.com/player/v1/${encodeURIComponent(postId)}?autoplay=1&controls=1&progress_bar=1&play_button=1&volume_control=1&fullscreen_button=1&description=1&rel=0&muted=${mutedFlag}`;
    }
    return null;
}

function loadEntertainment(service, target, preserveInput = false) {
    const src = buildEntertainmentUrl(service, target);
    if (!src) {
        setStatus(`INVALID ${service.toUpperCase()} ${service === 'kick' ? 'CHANNEL' : 'URL'}`, true, 5000);
        return false;
    }

    entertainmentScreen.innerHTML = '';
    const iframe = document.createElement('iframe');
    iframe.className = 'entertainment-frame';
    iframe.src = src;
    iframe.title = `${service} entertainment player`;
    iframe.allow = 'autoplay; encrypted-media; picture-in-picture; fullscreen';
    iframe.allowFullscreen = true;
    iframe.referrerPolicy = 'strict-origin-when-cross-origin';
    entertainmentScreen.appendChild(iframe);

    entertainmentService = service;
    entertainmentTarget = target;
    entertainmentActive = true;
    if (!preserveInput) entertainmentInput.value = target;
    lastAppliedMediaVolume = -1;
    applySmoothedMediaVolume(true);
    setStatus(`${service.toUpperCase()} ENTERTAINMENT ACTIVE`, false, 3000);
    return true;
}

function stopEntertainment() {
    if (!entertainmentScreen) return;
    entertainmentScreen.innerHTML = '';
    const placeholder = document.createElement('div');
    placeholder.id = 'entertainment-placeholder';
    placeholder.className = 'entertainment-placeholder';
    placeholder.innerHTML = '<strong>ENTERTAINMENT READY</strong><span>Choose YouTube, Kick, or TikTok above.</span><small>Video playback is local to you and does not change the vehicle radio for other players.</small>';
    entertainmentScreen.appendChild(placeholder);
    entertainmentActive = false;
    entertainmentTarget = null;
    lastAppliedMediaVolume = -1;
    applySmoothedMediaVolume(true);
}

function switchMediaSource(nextSource) {
    if (activeMediaSource === nextSource) {
        return;
    }

    debugStream(`Switching media source ${activeMediaSource} -> ${nextSource}`);
    if (activeMediaSource === 'youtube') {
        stopYouTube();
    } else if (activeMediaSource === 'stream') {
        stopStream();
    }

    activeMediaSource = nextSource;
    lastAppliedMediaVolume = -1;
}

function initializeYouTubePlayer() {
    if (youtubePlayer || youtubeApiRequested) {
        return;
    }

    if (youtubeApiAttempts >= 3) {
        setStatus('YOUTUBE API UNAVAILABLE', true, 8000);
        return;
    }

    youtubeApiRequested = true;
    youtubeApiAttempts += 1;
    ensureYouTubePlayerHost();

    if (window.YT && typeof window.YT.Player === 'function') {
        createYouTubePlayer();
        startYouTubeReadyTimeout(null);
        return;
    }

    const script = document.createElement('script');
    script.src = 'https://www.youtube.com/iframe_api';
    script.async = true;
    script.onerror = () => handleYouTubeApiLoadFailure(script);
    document.head.appendChild(script);

    startYouTubeReadyTimeout(script);
}

function startYouTubeReadyTimeout(script) {
    youtubeReadyTimeout = setTimeout(() => {
        if (!youtubePlayerReady && youtubeApiRequested) {
            handleYouTubeApiLoadFailure(script);
        }
    }, 10000);
}

function ensureYouTubePlayerHost() {
    if (document.getElementById('youtube-player-host')) {
        return;
    }

    const host = document.createElement('div');
    host.id = 'youtube-player-host';
    host.className = 'youtube-player-host';
    host.setAttribute('aria-hidden', 'true');
    document.body.appendChild(host);
}

function handleYouTubeApiLoadFailure(script) {
    if (!youtubeApiRequested) {
        return;
    }

    youtubeApiRequested = false;
    if (youtubeReadyTimeout) {
        clearTimeout(youtubeReadyTimeout);
        youtubeReadyTimeout = null;
    }
    if (script) {
        script.remove();
    }
    if (youtubePlayer && !youtubePlayerReady) {
        try {
            youtubePlayer.destroy();
        } catch (_) {
            // The partially initialized iframe may not expose destroy yet.
        }
        youtubePlayer = null;
        ensureYouTubePlayerHost();
    }
    debugYouTube('YouTube iframe API failed to initialize');
    youtubePlayButton.disabled = true;
    setStatus('YOUTUBE API UNAVAILABLE', true, 8000);
    postNUI('youtubeError', {
        code: 0,
        recoverable: true,
        videoId: activeRadioState ? activeRadioState.videoId : null
    });

    if (youtubeApiAttempts < 3 && activeRadioState && activeRadioState.source === 'youtube') {
        youtubeRetryTimer = setTimeout(() => {
            youtubeRetryTimer = null;
            if (activeRadioState && activeRadioState.source === 'youtube') {
                initializeYouTubePlayer();
            }
        }, 5000);
    }
}

function createYouTubePlayer() {
    if (youtubePlayer || !window.YT || typeof window.YT.Player !== 'function') {
        return;
    }

    debugYouTube(`Creating YouTube iframe window.YT=${Boolean(window.YT)} YT.Player=${Boolean(window.YT && window.YT.Player)}`);
    youtubePlayer = new window.YT.Player('youtube-player-host', {
        width: 200,
        height: 200,
        playerVars: {
            autoplay: 0,
            controls: 0,
            disablekb: 1,
            fs: 0,
            origin: window.location.origin,
            playsinline: 1,
            rel: 0
        },
        events: {
            onReady: handleYouTubeReady,
            onStateChange: handleYouTubeStateChange,
            onError: handleYouTubeError,
            onAutoplayBlocked: handleYouTubeAutoplayBlocked
        }
    });
}

window.onYouTubeIframeAPIReady = () => {
    if (youtubeApiRequested || (activeRadioState && activeRadioState.source === 'youtube')) {
        createYouTubePlayer();
    }
};

function handleYouTubeReady() {
    youtubePlayerReady = true;
    youtubeApiRequested = false;
    youtubeApiAttempts = 0;
    if (youtubeRetryTimer) {
        clearTimeout(youtubeRetryTimer);
        youtubeRetryTimer = null;
    }
    if (youtubeReadyTimeout) {
        clearTimeout(youtubeReadyTimeout);
        youtubeReadyTimeout = null;
    }

    const iframe = youtubePlayer.getIframe();
    iframe.setAttribute('allow', 'autoplay; encrypted-media');
    youtubePlayButton.disabled = !canControl;

    debugYouTube('YouTube iframe ready');
    initializeMetadataPlayer();
    debugYouTubeSnapshot('YouTube ready');

    if (pendingRadioState) {
        const state = { ...pendingRadioState };
        if (state.playing === true && activeRadioState) {
            state.position = getExpectedPosition();
        }
        pendingRadioState = null;
        applyRadioState(state, true);
    } else if (isOpen) {
        setStatus('SYSTEM READY');
    }
}

function handleYouTubeStateChange(event) {
    updateVideoMetadata();
    debugYouTube(`YouTube state: ${getYouTubeStateName(event.data)}`);
    debugYouTubeSnapshot('YouTube state detail');

    const eventData = event.target && event.target.getVideoData
        ? event.target.getVideoData()
        : null;
    const eventVideoId = eventData && eventData.video_id;

    if (window.YT && event.data === window.YT.PlayerState.PLAYING) {
        autoplayBlocked = false;
    }

    if (window.YT && event.data === window.YT.PlayerState.ENDED) {
        if (!VIDEO_ID_PATTERN.test(eventVideoId || '')
            || !activeRadioState
            || eventVideoId !== activeRadioState.videoId) {
            return;
        }

        // Latch this exact authoritative revision as finished. FiveM can still
        // deliver/re-apply the old "playing=true" state for a short period while
        // the server processes trackEnded. Without this guard, applyRadioState()
        // can call playVideo()/seekTo() and restart the finished video.
        endedYouTubeGuard = {
            videoId: activeRadioState.videoId,
            revision: activeRadioState.revision
        };
        activeRadioState.playing = false;

        // Explicitly keep the iframe stopped until a NEW server revision arrives
        // (next queued track or authoritative stop). This is local only and does
        // not change server authority.
        try {
            youtubePlayer.pauseVideo();
        } catch (_) {}

        renderNowPlaying();
        postNUI('youtubeEnded', {
            videoId: activeRadioState.videoId
        });
    }
}

function handleYouTubeError(event) {
    const code = Number(event.data) || 0;
    debugYouTube(`YouTube error: ${code}`);
    debugYouTubeSnapshot('YouTube error detail');
    const eventData = event.target && event.target.getVideoData
        ? event.target.getVideoData()
        : null;
    const eventVideoId = eventData && eventData.video_id;

    const matchesActiveVideo = VIDEO_ID_PATTERN.test(eventVideoId || '')
        && activeRadioState
        && eventVideoId === activeRadioState.videoId;
    const matchesProvisionalVideo = eventVideoId === provisionalVideoId;

    if (!matchesActiveVideo && !matchesProvisionalVideo) {
        return;
    }

    const messages = {
        2: 'INVALID VIDEO',
        5: 'HTML5 PLAYBACK ERROR',
        100: 'VIDEO UNAVAILABLE',
        101: 'EMBEDDING DISABLED',
        150: 'EMBEDDING DISABLED',
        153: 'YOUTUBE CLIENT BLOCKED'
    };

    if (matchesActiveVideo) {
        activeRadioState.playing = false;
        pauseYouTube();
        renderNowPlaying();
    } else {
        cancelPreparedPlayback(eventVideoId);
    }
    setStatus(messages[code] || 'YOUTUBE PLAYBACK ERROR', true, 8000);
    postNUI('youtubeError', {
        code,
        videoId: eventVideoId
    });
}

function handleYouTubeAutoplayBlocked() {
    autoplayBlocked = true;
    setPlaying(false);
    playPauseButton.disabled = false;
    setStatus('AUTOPLAY BLOCKED - PRESS RESUME', true, 8000);
    postNUI('youtubeError', {
        code: -1,
        recoverable: true,
        videoId: activeRadioState ? activeRadioState.videoId : null
    });
}

function playYouTube(videoId, position = 0, volume = 100) {
    switchMediaSource('youtube');
    initializeYouTubePlayer();
    if (!youtubePlayerReady) {
        return false;
    }

    loadedVideoId = videoId;
    debugYouTube(`Loading video: ${videoId}`);
    setMediaVolume(volume);
    applySmoothedMediaVolume(true);
    youtubePlayer.loadVideoById({
        videoId,
        startSeconds: Math.max(0, Number(position) || 0)
    });
    youtubePlayer.unMute();
    youtubePlayer.playVideo();
    debugYouTubeSnapshot('Playback requested', position);
    return true;
}

function pauseYouTube() {
    if (youtubePlayerReady && youtubePlayer) {
        youtubePlayer.pauseVideo();
    }
}

function resumeYouTube(volume = 100) {
    if (youtubePlayerReady && youtubePlayer) {
        youtubePlayer.unMute();
        setMediaVolume(volume);
        youtubePlayer.playVideo();
        debugYouTubeSnapshot('Resume requested');
    }
}

function stopYouTube() {
    if (youtubeRetryTimer) {
        clearTimeout(youtubeRetryTimer);
        youtubeRetryTimer = null;
    }
    if (provisionalCleanupTimer) {
        clearTimeout(provisionalCleanupTimer);
        provisionalCleanupTimer = null;
    }

    pendingRadioState = null;
    loadedVideoId = null;
    provisionalVideoId = null;
    currentTitle = '';
    autoplayBlocked = false;
    if (youtubePlayerReady && youtubePlayer) {
        youtubePlayer.stopVideo();
    }
}

function setStreamStatus(status) {
    if (streamPlaybackStatus === status) {
        return;
    }

    streamPlaybackStatus = status;
    debugStream(`Stream status: ${status.toUpperCase()}`);
    if (activeRadioState && activeRadioState.source === 'stream') {
        renderNowPlaying();
    }
}

function reportStreamError(error) {
    setStreamStatus('error');
    const code = streamPlayer.error ? streamPlayer.error.code : 'play-rejected';
    debugStream(`Stream playback error code=${code} message=${error ? String(error) : 'media-error'}`);

    if (!streamErrorNotified) {
        streamErrorNotified = true;
        postNUI('streamError', { code });
    }
}

function stopStream() {
    streamPlayAttempt += 1;
    streamPlayer.pause();
    streamPlayer.removeAttribute('src');
    streamPlayer.load();
    loadedStreamUrl = null;
    streamPlaybackBlocked = false;
    streamErrorNotified = false;
    setStreamStatus('idle');
}

function pauseStream() {
    streamPlayAttempt += 1;
    streamPlayer.pause();
    streamPlaybackBlocked = false;
    setStreamStatus('paused');
}

async function resumeStream(reconnect = false) {
    if (!loadedStreamUrl) {
        return false;
    }

    if (reconnect) {
        streamPlayer.src = loadedStreamUrl;
        streamPlayer.load();
    }

    const attemptedUrl = loadedStreamUrl;
    const attempt = ++streamPlayAttempt;
    setStreamStatus('connecting');
    try {
        const playResult = streamPlayer.play();
        if (playResult && typeof playResult.then === 'function') {
            await playResult;
        }
        if (attempt !== streamPlayAttempt
            || activeMediaSource !== 'stream'
            || loadedStreamUrl !== attemptedUrl) {
            return false;
        }
        streamPlaybackBlocked = false;
        return true;
    } catch (error) {
        if (attempt !== streamPlayAttempt
            || activeMediaSource !== 'stream'
            || loadedStreamUrl !== attemptedUrl) {
            return false;
        }
        streamPlaybackBlocked = true;
        reportStreamError(error);
        return false;
    }
}

function playStream(url, volume, shouldPlay) {
    switchMediaSource('stream');
    const streamChanged = loadedStreamUrl !== url;

    if (streamChanged) {
        stopStream();
        activeMediaSource = 'stream';
        loadedStreamUrl = url;
        streamErrorNotified = false;
        streamPlayer.src = url;
        streamPlayer.preload = 'none';
        setMediaVolume(volume);
        applySmoothedMediaVolume(true);
        setStreamStatus('connecting');
        streamPlayer.load();
        debugStream(`Loading stream: ${activeRadioState ? activeRadioState.stationName : 'Unknown Station'}`);
    }

    if (shouldPlay) {
        resumeStream(false);
    } else {
        pauseStream();
    }
}

function initializeStreamPlayer() {
    streamPlayer.preload = 'none';
    streamPlayer.addEventListener('loadstart', () => {
        if (activeMediaSource === 'stream') setStreamStatus('connecting');
    });
    streamPlayer.addEventListener('waiting', () => {
        if (activeMediaSource === 'stream') setStreamStatus('buffering');
    });
    streamPlayer.addEventListener('stalled', () => {
        if (activeMediaSource === 'stream') setStreamStatus('buffering');
    });
    streamPlayer.addEventListener('playing', () => {
        if (activeMediaSource === 'stream') {
            streamPlaybackBlocked = false;
            streamErrorNotified = false;
            setStreamStatus('live');
            debugStream('Stream playback started');
        }
    });
    streamPlayer.addEventListener('error', () => {
        if (activeMediaSource === 'stream') reportStreamError();
    });
}

function seekYouTube(position) {
    if (youtubePlayerReady && youtubePlayer) {
        youtubePlayer.seekTo(Math.max(0, Number(position) || 0), true);
    }
}

function setMediaVolume(volume) {
    targetEffectiveVolume = clamp(Number(volume) || 0, 0, 100);
}

function applySmoothedMediaVolume(force = false) {
    const desiredVolume = (streamerMode || entertainmentActive) ? 0 : targetEffectiveVolume;
    const difference = desiredVolume - currentEffectiveVolume;

    if (force || Math.abs(difference) < 0.1) {
        currentEffectiveVolume = desiredVolume;
    } else {
        currentEffectiveVolume += difference * 0.25;
    }

    const roundedVolume = Math.round(clamp(currentEffectiveVolume, 0, 100));
    if (roundedVolume === lastAppliedMediaVolume) {
        return;
    }

    if (activeMediaSource === 'youtube' && youtubePlayerReady && youtubePlayer) {
        youtubePlayer.setVolume(roundedVolume);
        lastAppliedMediaVolume = roundedVolume;
    } else if (activeMediaSource === 'stream') {
        streamPlayer.volume = roundedVolume / 100;
        lastAppliedMediaVolume = roundedVolume;
    }
}

function startVolumeSmoothing() {
    if (volumeSmoothingTimer) {
        return;
    }

    volumeSmoothingTimer = setInterval(() => {
        applySmoothedMediaVolume(false);
    }, 75);
}

function verifyYouTubeAudio(videoId, requestedPosition) {
    setTimeout(() => {
        if (!youtubePlayerReady
            || !youtubePlayer
            || !activeRadioState
            || activeRadioState.videoId !== videoId
            || !activeRadioState.playing) {
            return;
        }

        debugYouTubeSnapshot('Post-playback audio check', requestedPosition);
        if (youtubePlayer.getPlayerState() === window.YT.PlayerState.PLAYING
            && youtubePlayer.isMuted()
            && !autoplayBlocked) {
            handleYouTubeAutoplayBlocked();
        }
    }, 250);
}

function prepareYouTubePlayback(videoId, volume) {
    if (!youtubePlayerReady || !youtubePlayer) {
        return false;
    }

    if (activeRadioState && activeRadioState.source === 'youtube') {
        youtubePlayer.unMute();
        debugYouTubeSnapshot('Existing player already activated');
        return true;
    }

    provisionalVideoId = videoId;
    if (provisionalCleanupTimer) {
        clearTimeout(provisionalCleanupTimer);
    }
    provisionalCleanupTimer = setTimeout(() => {
        cancelPreparedPlayback(videoId);
    }, 10000);
    loadedVideoId = videoId;
    currentTitle = '';
    debugYouTube(`Loading video: ${videoId}`);
    youtubePlayer.mute();
    youtubePlayer.loadVideoById({ videoId, startSeconds: 0 });
    debugYouTubeSnapshot('Prepared from PLAY interaction', 0);
    return true;
}

function cancelPreparedPlayback(expectedVideoId = null) {
    if (!provisionalVideoId
        || (expectedVideoId !== null && provisionalVideoId !== expectedVideoId)) {
        return;
    }

    const cancelledVideoId = provisionalVideoId;
    provisionalVideoId = null;
    if (provisionalCleanupTimer) {
        clearTimeout(provisionalCleanupTimer);
        provisionalCleanupTimer = null;
    }
    if (loadedVideoId === cancelledVideoId
        && (!activeRadioState || activeRadioState.videoId !== cancelledVideoId)) {
        loadedVideoId = null;
        youtubePlayer.stopVideo();
    }
    debugYouTube('Cancelled unapproved prepared playback');
}

function getExpectedPosition() {
    if (!activeRadioState || activeRadioState.source !== 'youtube') {
        return 0;
    }

    const elapsed = activeRadioState.playing
        ? (performance.now() - activeRadioState.receivedAt) / 1000
        : 0;

    return Math.max(0, activeRadioState.position + elapsed);
}

function applyRadioState(rawState, force = false) {
    if (!rawState || typeof rawState !== 'object') {
        clearLocalPlayback();
        return;
    }

    const incomingRevision = Number(rawState.revision) || 0;
    if (activeRadioState && incomingRevision < activeRadioState.revision) {
        return;
    }

    const incomingVideoId = VIDEO_ID_PATTERN.test(rawState.videoId || '') ? rawState.videoId : null;
    if (endedYouTubeGuard) {
        const isFinishedRevision = rawState.source === 'youtube'
            && incomingVideoId === endedYouTubeGuard.videoId
            && incomingRevision <= endedYouTubeGuard.revision;

        if (isFinishedRevision) {
            // Ignore only the stale playback portion of this state. UI/queue data
            // from the same revision is already represented locally; most
            // importantly, do not seek/resume the finished iframe.
            if (youtubePlayerReady && youtubePlayer) {
                try { youtubePlayer.pauseVideo(); } catch (_) {}
            }
            return;
        }

        // A newer authoritative revision (queue advance, stop, new track, etc.)
        // releases the end guard and may control playback normally.
        endedYouTubeGuard = null;
    }

    const requestedSource = rawState.source;
    const videoId = VIDEO_ID_PATTERN.test(rawState.videoId || '') ? rawState.videoId : null;
    const streamUrl = isValidStreamUrl(rawState.streamUrl) ? rawState.streamUrl : null;
    const source = requestedSource === 'youtube' && videoId
        ? 'youtube'
        : requestedSource === 'stream' && streamUrl
            ? 'stream'
            : 'none';
    const position = Math.max(0, Number(rawState.position) || 0);
    const volume = clamp(Number(rawState.volume) || 0, 0, maxVolume);
    const requestedLocalVolume = Number(rawState.localVolume);
    const effectiveVolume = Number.isFinite(requestedLocalVolume)
        ? clamp(requestedLocalVolume, 0, 100)
        : volume;
    const previousState = activeRadioState;
    const playingChanged = !previousState || previousState.playing !== (rawState.playing === true);

    if (source !== 'youtube'
        || rawState.playing !== true
        || !previousState
        || previousState.videoId !== videoId
        || previousState.playing !== true) {
        autoplayBlocked = false;
    }

    activeRadioState = {
        vehicleNetworkId: Number(rawState.vehicleNetworkId) || 0,
        source,
        videoId,
        streamUrl,
        stationId: typeof rawState.stationId === 'string' ? rawState.stationId : null,
        stationName: typeof rawState.stationName === 'string' ? rawState.stationName : 'Custom Stream',
        genre: typeof rawState.genre === 'string' ? rawState.genre : 'Radio',
        volume,
        localVolume: effectiveVolume,
        playing: rawState.playing === true && source !== 'none',
        position,
        revision: incomingRevision,
        receivedAt: performance.now(),
        title: typeof rawState.title === 'string' ? rawState.title : '',
        author: typeof rawState.author === 'string' ? rawState.author : '',
        duration: Math.max(0, Number(rawState.duration) || 0),
        queue: Array.isArray(rawState.queue) ? rawState.queue.slice(0, queueSettings.maxItems) : []
    };

    if (videoId && videoId === provisionalVideoId) {
        provisionalVideoId = null;
        if (provisionalCleanupTimer) {
            clearTimeout(provisionalCleanupTimer);
            provisionalCleanupTimer = null;
        }
    }

    localEffectiveVolume = effectiveVolume;
    if (source === 'youtube' && activeRadioState.playing) recordRecentTrack(activeRadioState);
    renderLibrary();

    if (!statusIsError) {
        statusLockedUntil = 0;
    }

    volumeSlider.value = String(volume);
    updateVolumeDisplay();
    setMediaVolume(effectiveVolume);

    if (source === 'none') {
        pendingRadioState = null;
        switchMediaSource('none');
        localEffectiveVolume = 0;
        setMediaVolume(0);
        applySmoothedMediaVolume(true);
        renderNowPlaying();
        return;
    }

    if (source === 'stream') {
        pendingRadioState = null;
        const streamChanged = activeMediaSource !== 'stream' || loadedStreamUrl !== streamUrl;
        switchMediaSource('stream');

        if (streamChanged) {
            playStream(streamUrl, effectiveVolume, activeRadioState.playing);
        } else if (activeRadioState.playing) {
            if (force || playingChanged || streamPlayer.paused || streamPlaybackStatus === 'error') {
                resumeStream(playingChanged);
            }
        } else if (!streamPlayer.paused || streamPlaybackStatus !== 'paused') {
            pauseStream();
        }

        setMediaVolume(effectiveVolume);
        renderNowPlaying();
        return;
    }

    switchMediaSource('youtube');
    initializeYouTubePlayer();
    if (!youtubePlayerReady) {
        pendingRadioState = rawState;
        renderNowPlaying();
        setStatus('LOADING YOUTUBE', false, 30000);
        return;
    }

    const videoChanged = loadedVideoId !== videoId;
    if (videoChanged) {
        currentTitle = activeRadioState.title || '';
        currentAuthor = activeRadioState.author || '';
        lastMetadataVideoId = null;
        if (activeRadioState.playing) {
            playYouTube(videoId, position, effectiveVolume);
        } else {
            loadedVideoId = videoId;
            youtubePlayer.cueVideoById({ videoId, startSeconds: position });
        }
    } else {
        const actual = Number(youtubePlayer.getCurrentTime()) || 0;
        if (force || Math.abs(actual - position) > 0.75) {
            seekYouTube(position);
        }

        const playerState = youtubePlayer.getPlayerState();
        if (activeRadioState.playing) {
            youtubePlayer.unMute();
            if (force || playingChanged || playerState !== window.YT.PlayerState.PLAYING) {
                resumeYouTube(effectiveVolume);
            }
        } else if (force || playingChanged || playerState !== window.YT.PlayerState.PAUSED) {
            pauseYouTube();
        }
    }

    setMediaVolume(effectiveVolume);
    debugYouTubeSnapshot('Synchronized state applied', position);
    if (activeRadioState.playing) {
        verifyYouTubeAudio(videoId, position);
    }
    renderNowPlaying();
}

function clearLocalPlayback() {
    endedYouTubeGuard = null;
    cancelPreparedPlayback();
    switchMediaSource('none');
    activeRadioState = null;
    pendingRadioState = null;
    currentTitle = '';
    currentAuthor = '';
    lastMetadataVideoId = null;
    localEffectiveVolume = 0;
    currentEffectiveVolume = 0;
    targetEffectiveVolume = 0;
    lastAppliedMediaVolume = -1;
    playbackSlider.value = '0';
    playbackSlider.max = '1';
    setRangeFill(playbackSlider, 0, 1);
    renderNowPlaying();
}

function applyLocalVolume(payload) {
    if (!activeRadioState
        || Number(payload.vehicleNetworkId) !== Number(activeRadioState.vehicleNetworkId)
        || !Number.isFinite(Number(payload.volume))) {
        return;
    }

    localEffectiveVolume = clamp(Number(payload.volume), 0, 100);
    activeRadioState.localVolume = localEffectiveVolume;
    if (pendingRadioState
        && Number(pendingRadioState.vehicleNetworkId) === Number(payload.vehicleNetworkId)) {
        pendingRadioState.localVolume = localEffectiveVolume;
    }
    setMediaVolume(localEffectiveVolume);
}

function updateVideoMetadata() {
    if (!youtubePlayerReady || !youtubePlayer || !activeRadioState || activeRadioState.source !== 'youtube') {
        return;
    }

    const videoData = youtubePlayer.getVideoData ? youtubePlayer.getVideoData() : {};
    if (!videoData || videoData.video_id !== activeRadioState.videoId) {
        return;
    }

    if (videoData.title) currentTitle = videoData.title;
    if (videoData.author) currentAuthor = videoData.author;
    if (activeRadioState) { activeRadioState.title = currentTitle; activeRadioState.author = currentAuthor; }
    recordRecentTrack(activeRadioState);
    renderLibrary();
    const duration = Number(youtubePlayer.getDuration ? youtubePlayer.getDuration() : 0) || 0;

    if (videoData.video_id !== lastMetadataVideoId && (currentTitle || currentAuthor || duration > 0)) {
        lastMetadataVideoId = videoData.video_id;
        postNUI('youtubeMetadata', {
            videoId: videoData.video_id,
            title: currentTitle,
            author: currentAuthor,
            duration
        });
    }
}

function getPlayerPosition() {
    if (youtubePlayerReady && youtubePlayer && loadedVideoId) {
        const position = Number(youtubePlayer.getCurrentTime());
        if (Number.isFinite(position)) {
            return Math.max(0, position);
        }
    }

    return getExpectedPosition();
}

function updatePlaybackDisplay() {
    const hasYouTube = activeRadioState
        && activeRadioState.source === 'youtube'
        && activeRadioState.videoId;

    playbackProgress.hidden = !hasYouTube;

    if (!hasYouTube) {
        playbackSlider.disabled = true;
        playbackSlider.value = '0';
        playbackSlider.max = '1';
        playbackTime.textContent = '0:00';
        setRangeFill(playbackSlider, 0, 1);
        return;
    }

    const position = isSeeking ? Number(playbackSlider.value) : getPlayerPosition();
    const playerDuration = youtubePlayerReady && youtubePlayer
        ? Number(youtubePlayer.getDuration()) || 0
        : 0;
    const duration = playerDuration || Number(activeRadioState.duration) || 0;

    if (!isSeeking) {
        playbackSlider.max = String(Math.max(duration, position, 1));
        playbackSlider.value = String(clamp(position, 0, Number(playbackSlider.max)));
    }

    playbackSlider.disabled = !canControl || duration <= 0;
    playbackTime.textContent = duration > 0
        ? `${formatTime(position)} / ${formatTime(duration)}`
        : formatTime(position);
    setRangeFill(playbackSlider, Number(playbackSlider.value), Number(playbackSlider.max));
}

function renderNowPlaying() {
    renderQueue();
    updateArtwork();
    const hasYouTube = activeRadioState
        && activeRadioState.source === 'youtube'
        && activeRadioState.videoId;
    const hasStream = activeRadioState
        && activeRadioState.source === 'stream'
        && activeRadioState.streamUrl;

    if (!hasYouTube && !hasStream) {
        document.getElementById('now-playing-title').textContent = 'NOW PLAYING';
        trackTitle.textContent = 'No source selected';
        trackSource.textContent = 'Choose a source below';
        setPlaying(false);
        setPlaybackStatus('SYSTEM READY');
        updatePlaybackDisplay();
        return;
    }

    if (hasStream) {
        const displayStatus = activeRadioState.playing
            ? streamPlaybackStatus === 'live'
                ? 'LIVE'
                : streamPlaybackStatus === 'error'
                    ? 'STREAM ERROR'
                    : streamPlaybackStatus === 'buffering'
                        ? 'BUFFERING...'
                        : 'CONNECTING...'
            : 'PAUSED';

        document.getElementById('now-playing-title').textContent = 'LIVE RADIO';
        trackTitle.textContent = activeRadioState.stationName || 'Custom Stream';
        trackSource.textContent = `${displayStatus === 'LIVE' ? '● LIVE' : displayStatus} • ${activeRadioState.genre || 'Radio'} • ${activeRadioState.volume}%`;
        setPlaying(activeRadioState.playing && !streamPlaybackBlocked);
        if (streamPlaybackStatus === 'error') {
            setStatus('STREAM ERROR', true, 2000);
        } else {
            setPlaybackStatus(displayStatus);
        }
        updatePlaybackDisplay();
        return;
    }

    const playbackState = activeRadioState.playing ? 'PLAYING' : 'PAUSED';
    const position = getPlayerPosition();

    updateVideoMetadata();
    document.getElementById('now-playing-title').textContent = 'NOW PLAYING';
    trackTitle.textContent = currentTitle || activeRadioState.title || activeRadioState.videoId;
    const author = currentAuthor || activeRadioState.author || 'YouTube';
    trackSource.textContent = `${author} • ${playbackState} • ${formatTime(position)} • ${activeRadioState.volume}%`;
    setPlaying(activeRadioState.playing && !autoplayBlocked);
    setPlaybackStatus(playbackState);
    updatePlaybackDisplay();
}

function checkPlaybackDrift() {
    if (!activeRadioState
        || endedYouTubeGuard
        || activeRadioState.source !== 'youtube'
        || !activeRadioState.playing
        || autoplayBlocked
        || !youtubePlayerReady
        || loadedVideoId !== activeRadioState.videoId) {
        return;
    }

    const expected = getExpectedPosition();
    const actual = Number(youtubePlayer.getCurrentTime()) || 0;
    const drift = Math.abs(expected - actual);

    if (drift > syncSettings.DriftThreshold) {
        seekYouTube(expected);
        resumeYouTube(localEffectiveVolume);

        if (debugEnabled) {
            console.log(`[acg_radio] sync expected=${expected.toFixed(1)} actual=${actual.toFixed(1)}`);
            postNUI('syncReport', { expected, actual });
        }
    }
}

function restartDriftTimer() {
    if (driftTimer) {
        clearInterval(driftTimer);
    }

    driftTimer = setInterval(checkPlaybackDrift, syncSettings.DriftCheckInterval);
}

window.addEventListener('message', (event) => {
    const payload = event.data || {};

    if (payload.action === 'initialize') {
        applySettings(payload.settings || {});
    } else if (payload.action === 'openRadio') {
        showRadio(payload);
    } else if (payload.action === 'closeRadio') {
        hideRadio();
    } else if (payload.action === 'syncRadioState') {
        applyRadioState(payload.state);
    } else if (payload.action === 'stopLocalPlayback') {
        clearLocalPlayback();
    } else if (payload.action === 'setLocalVolume') {
        applyLocalVolume(payload);
    } else if (payload.action === 'setStreamerMode') {
        setStreamerMode(payload.enabled === true, payload.restoreVolume);
    } else if (payload.action === 'updateVehicleRole') {
        setControlPermission(payload.isDriver === true, payload.driverOnly === true);
    } else if (payload.action === 'radioError') {
        setStatus(payload.message || 'RADIO REQUEST FAILED', true, 5000);
    }
});

document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && isOpen) {
        event.preventDefault();
        closeRadio();
    }
});

closeButton.addEventListener('click', closeRadio);
radioHeader.addEventListener('pointerdown', (event) => beginWindowPointer(event, 'drag'));
windowResizeHandle.addEventListener('pointerdown', (event) => beginWindowPointer(event, 'resize'));
resetWindowButton.addEventListener('click', (event) => { event.stopPropagation(); resetWindowGeometry(); });
window.addEventListener('resize', () => { if (windowGeometry) applyWindowGeometry(true); });

document.querySelectorAll('.tab-button').forEach((button) => {
    button.addEventListener('click', () => selectTab(button.dataset.tab));
});

async function requestConfiguredStation(stationId) {
    if (!canControl || typeof stationId !== 'string') {
        return;
    }

    const result = await postNUI('playStation', { stationId });
    if (result.ok) {
        setStatus('WAITING FOR SERVER', false, 3000);
    }
}

document.querySelectorAll('.entertainment-service').forEach((button) => {
    button.addEventListener('click', () => setEntertainmentService(button.dataset.service));
});

entertainmentForm.addEventListener('submit', (event) => {
    event.preventDefault();
    const value = entertainmentInput.value.trim();
    loadEntertainment(entertainmentService, value);
});

entertainmentStopButton.addEventListener('click', () => {
    stopEntertainment();
    setStatus('ENTERTAINMENT STOPPED', false, 2500);
});

queueAddButton.addEventListener('click', async () => {
    if (!canControl || !queueSettings.enabled) return;
    const url = document.getElementById('youtube-url').value.trim();
    const videoId = extractYouTubeVideoId(url);
    if (!videoId) {
        setStatus('INVALID YOUTUBE URL', true, 5000);
        return;
    }

    setStatus('READING YOUTUBE METADATA', false, 5000);
    const metadata = await resolveYouTubeMetadata(videoId);
    const result = await postNUI('addToQueue', metadata);
    if (result.ok) {
        document.getElementById('youtube-url').value = '';
        setStatus('ADDED TO QUEUE', false, 3000);
    }
});

skipButton.addEventListener('click', async () => {
    if (!canControl || !activeRadioState || activeRadioState.source !== 'youtube') return;
    const result = await postNUI('skip');
    if (result.ok) setStatus('WAITING FOR SERVER', false, 3000);
});

favoriteButton.addEventListener('click', toggleFavoriteCurrent);
clearHistoryButton.addEventListener('click', () => {
    recentHistory = [];
    lastHistoryVideoId = null;
    persistLibrary();
    renderLibrary();
    setStatus('HISTORY CLEARED', false, 2000);
});

youtubeForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const url = document.getElementById('youtube-url').value.trim();
    const videoId = extractYouTubeVideoId(url);

    if (!videoId) {
        setStatus('INVALID YOUTUBE URL', true, 5000);
        trackSource.textContent = 'Use a YouTube watch, shorts, embed, live, or youtu.be URL';
        return;
    }

    if (!youtubePlayerReady || !youtubePlayer) {
        initializeYouTubePlayer();
        debugYouTubeSnapshot('PLAY blocked while player loads', 0);
        setStatus('YOUTUBE PLAYER LOADING - PRESS PLAY AGAIN', true, 5000);
        return;
    }

    prepareYouTubePlayback(videoId, Number(volumeSlider.value));

    const result = await postNUI('playYoutube', { videoId });
    if (result.ok) {
        setStatus('WAITING FOR SERVER', false, 3000);
    } else {
        cancelPreparedPlayback(videoId);
    }
});

streamForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!streamSettings.allowCustomUrls) {
        setStatus('CUSTOM STREAMS DISABLED', true, 5000);
        return;
    }

    const streamUrl = document.getElementById('stream-url').value.trim();
    const stationName = document.getElementById('station-name').value.trim();
    if (!isValidStreamUrl(streamUrl)) {
        setStatus('INVALID DIRECT STREAM URL', true, 5000);
        return;
    }

    const result = await postNUI('playStream', { streamUrl, stationName });
    if (result.ok) {
        setStatus('WAITING FOR SERVER', false, 3000);
    }
});

playPauseButton.addEventListener('click', async () => {
    if (!activeRadioState || activeRadioState.source === 'none') {
        setStatus('NO RADIO SOURCE', true, 3000);
        return;
    }

    if (autoplayBlocked && activeRadioState.playing) {
        autoplayBlocked = false;
        playPauseButton.disabled = !canControl;
        resumeYouTube(localEffectiveVolume);
        setStatus('RETRYING PLAYBACK', false, 3000);
        return;
    }

    if (activeRadioState.source === 'stream'
        && activeRadioState.playing
        && streamPlaybackBlocked) {
        streamPlaybackBlocked = false;
        playPauseButton.disabled = !canControl;
        resumeStream(false);
        setStatus('RETRYING STREAM', false, 3000);
        return;
    }

    const action = activeRadioState.playing ? 'pause' : 'resume';
    const result = await postNUI(action);
    if (result.ok) {
        setStatus('WAITING FOR SERVER', false, 3000);
    }
});

stopButton.addEventListener('click', async () => {
    const result = await postNUI('stop');
    if (result.ok) {
        setStatus('WAITING FOR SERVER', false, 3000);
    }
});

volumeSlider.addEventListener('input', updateVolumeDisplay);
volumeSlider.addEventListener('change', async () => {
    const result = await postNUI('setVolume', { volume: Number(volumeSlider.value) });
    if (result.ok) {
        setStatus('WAITING FOR SERVER', false, 3000);
    }
});

playbackSlider.addEventListener('input', () => {
    isSeeking = true;
    const position = Number(playbackSlider.value) || 0;
    playbackTime.textContent = formatTime(position);
    setRangeFill(playbackSlider, position, Number(playbackSlider.max));
});

playbackSlider.addEventListener('change', async () => {
    const position = Number(playbackSlider.value) || 0;
    const result = await postNUI('seek', { position });
    isSeeking = false;

    if (result.ok) {
        setStatus('WAITING FOR SERVER', false, 3000);
    }
});

function initializeUI() {
    hideRadio();
    clearLocalPlayback();
    initializeStreamPlayer();
    setEntertainmentService('youtube');
    updateVolumeDisplay();
    renderQueue();
    restartDriftTimer();
    startVolumeSmoothing();

    displayTimer = setInterval(() => {
        if (activeRadioState) {
            renderNowPlaying();
        }
    }, 500);

    postNUI('nuiReady');
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initializeUI, { once: true });
} else {
    initializeUI();
}
