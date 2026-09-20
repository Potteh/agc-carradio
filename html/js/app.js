const radioShell = document.getElementById('radio-shell');
const closeButton = document.getElementById('close-button');
const playPauseButton = document.getElementById('play-pause-button');
const stopButton = document.getElementById('stop-button');
const volumeSlider = document.getElementById('volume-slider');
const volumeValue = document.getElementById('volume-value');
const playbackSlider = document.getElementById('playback-slider');
const playbackTime = document.getElementById('playback-time');
const vehiclePlate = document.getElementById('vehicle-plate');
const occupantRole = document.getElementById('occupant-role');
const streamerModeIndicator = document.getElementById('streamer-mode-indicator');
const trackTitle = document.getElementById('track-title');
const trackSource = document.getElementById('track-source');
const systemStatus = document.getElementById('system-status');
const youtubeForm = document.getElementById('youtube-form');
const youtubePlayButton = youtubeForm.querySelector('button[type="submit"]');
const streamForm = document.getElementById('stream-form');

const VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/;

let isOpen = false;
let canControl = false;
let isSeeking = false;
let autoplayBlocked = false;
let youtubePlayer = null;
let youtubePlayerReady = false;
let youtubeApiRequested = false;
let youtubeApiAttempts = 0;
let youtubeRetryTimer = null;
let youtubeReadyTimeout = null;
let loadedVideoId = null;
let provisionalVideoId = null;
let currentTitle = '';
let pendingRadioState = null;
let activeRadioState = null;
let localEffectiveVolume = 0;
let currentEffectiveVolume = 0;
let targetEffectiveVolume = 0;
let lastAppliedYouTubeVolume = -1;
let streamerMode = false;
let debugEnabled = false;
let maxVolume = 100;
let driftTimer = null;
let displayTimer = null;
let volumeSmoothingTimer = null;
let statusLockedUntil = 0;
let statusIsError = false;
let syncSettings = {
    DriftCheckInterval: 5000,
    DriftThreshold: 2.5
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
    volumeSlider.disabled = !canControl;
    youtubePlayButton.disabled = !canControl || !youtubePlayerReady;
    updatePlaybackDisplay();
}

function applySettings(settings = {}) {
    if (isValidNumber(Number(settings.maxVolume))) {
        maxVolume = clamp(Number(settings.maxVolume), 1, 100);
        volumeSlider.max = String(maxVolume);
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

function setStreamerMode(enabled, restoreVolume = null) {
    streamerMode = enabled === true;
    streamerModeIndicator.hidden = !streamerMode;

    if (!streamerMode && Number.isFinite(Number(restoreVolume))) {
        localEffectiveVolume = clamp(Number(restoreVolume), 0, 100);
        if (activeRadioState) {
            activeRadioState.localVolume = localEffectiveVolume;
        }
    }

    setYouTubeVolume(localEffectiveVolume);
    applySmoothedYouTubeVolume(true);
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

    radioShell.hidden = false;
    radioShell.setAttribute('aria-hidden', 'false');
    requestAnimationFrame(() => radioShell.classList.add('visible'));
    isOpen = true;
    renderNowPlaying();

    if (!youtubePlayerReady) {
        setStatus('LOADING YOUTUBE PLAYER', false, 10000);
    }
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

        if (activeRadioState) {
            activeRadioState.playing = false;
        }
        renderNowPlaying();
        postNUI('youtubeEnded', {
            videoId: activeRadioState ? activeRadioState.videoId : null
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
        cancelPreparedPlayback();
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
    initializeYouTubePlayer();
    if (!youtubePlayerReady) {
        return false;
    }

    loadedVideoId = videoId;
    debugYouTube(`Loading video: ${videoId}`);
    setYouTubeVolume(volume);
    applySmoothedYouTubeVolume(true);
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
        setYouTubeVolume(volume);
        youtubePlayer.playVideo();
        debugYouTubeSnapshot('Resume requested');
    }
}

function stopYouTube() {
    if (youtubeRetryTimer) {
        clearTimeout(youtubeRetryTimer);
        youtubeRetryTimer = null;
    }

    pendingRadioState = null;
    loadedVideoId = null;
    provisionalVideoId = null;
    currentTitle = '';
    autoplayBlocked = false;
    localEffectiveVolume = 0;
    currentEffectiveVolume = 0;
    targetEffectiveVolume = 0;
    lastAppliedYouTubeVolume = -1;

    if (youtubePlayerReady && youtubePlayer) {
        youtubePlayer.stopVideo();
    }
}

function seekYouTube(position) {
    if (youtubePlayerReady && youtubePlayer) {
        youtubePlayer.seekTo(Math.max(0, Number(position) || 0), true);
    }
}

function setYouTubeVolume(volume) {
    targetEffectiveVolume = clamp(Number(volume) || 0, 0, 100);
}

function applySmoothedYouTubeVolume(force = false) {
    const desiredVolume = streamerMode ? 0 : targetEffectiveVolume;
    const difference = desiredVolume - currentEffectiveVolume;

    if (force || Math.abs(difference) < 0.1) {
        currentEffectiveVolume = desiredVolume;
    } else {
        currentEffectiveVolume += difference * 0.25;
    }

    const roundedVolume = Math.round(clamp(currentEffectiveVolume, 0, 100));
    if (youtubePlayerReady
        && youtubePlayer
        && roundedVolume !== lastAppliedYouTubeVolume) {
        youtubePlayer.setVolume(roundedVolume);
        lastAppliedYouTubeVolume = roundedVolume;
    }
}

function startVolumeSmoothing() {
    if (volumeSmoothingTimer) {
        return;
    }

    volumeSmoothingTimer = setInterval(() => {
        applySmoothedYouTubeVolume(false);
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
        setYouTubeVolume(volume);
        debugYouTubeSnapshot('Existing player already activated');
        return true;
    }

    provisionalVideoId = videoId;
    loadedVideoId = videoId;
    currentTitle = '';
    debugYouTube(`Loading video: ${videoId}`);
    youtubePlayer.mute();
    setYouTubeVolume(volume);
    youtubePlayer.loadVideoById({ videoId, startSeconds: 0 });
    debugYouTubeSnapshot('Prepared from PLAY interaction', 0);
    return true;
}

function cancelPreparedPlayback() {
    if (!provisionalVideoId) {
        return;
    }

    provisionalVideoId = null;
    loadedVideoId = null;
    youtubePlayer.stopVideo();
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

    const source = rawState.source === 'youtube' ? 'youtube' : 'none';
    const videoId = VIDEO_ID_PATTERN.test(rawState.videoId || '') ? rawState.videoId : null;
    const position = Math.max(0, Number(rawState.position) || 0);
    const volume = clamp(Number(rawState.volume) || 0, 0, maxVolume);
    const requestedLocalVolume = Number(rawState.localVolume);
    const effectiveVolume = Number.isFinite(requestedLocalVolume)
        ? clamp(requestedLocalVolume, 0, 100)
        : volume;
    const previousState = activeRadioState;
    const playingChanged = !previousState || previousState.playing !== (rawState.playing === true);

    if (source !== 'youtube'
        || !videoId
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
        volume,
        localVolume: effectiveVolume,
        playing: rawState.playing === true && source === 'youtube' && videoId !== null,
        position,
        revision: incomingRevision,
        receivedAt: performance.now()
    };

    if (videoId && videoId === provisionalVideoId) {
        provisionalVideoId = null;
    }

    localEffectiveVolume = effectiveVolume;

    if (!statusIsError) {
        statusLockedUntil = 0;
    }

    volumeSlider.value = String(volume);
    updateVolumeDisplay();
    setYouTubeVolume(effectiveVolume);

    if (source !== 'youtube' || !videoId) {
        stopYouTube();
        renderNowPlaying();
        return;
    }

    initializeYouTubePlayer();
    if (!youtubePlayerReady) {
        pendingRadioState = rawState;
        renderNowPlaying();
        setStatus('LOADING YOUTUBE', false, 30000);
        return;
    }

    const videoChanged = loadedVideoId !== videoId;
    if (videoChanged) {
        currentTitle = '';
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

    setYouTubeVolume(effectiveVolume);
    debugYouTubeSnapshot('Synchronized state applied', position);
    if (activeRadioState.playing) {
        verifyYouTubeAudio(videoId, position);
    }
    renderNowPlaying();
}

function clearLocalPlayback() {
    stopYouTube();
    activeRadioState = null;
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
    setYouTubeVolume(localEffectiveVolume);
}

function updateVideoMetadata() {
    if (!youtubePlayerReady || !youtubePlayer || !activeRadioState) {
        return;
    }

    const videoData = youtubePlayer.getVideoData();
    if (videoData && videoData.video_id === activeRadioState.videoId && videoData.title) {
        currentTitle = videoData.title;
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

    if (!hasYouTube) {
        playbackSlider.disabled = true;
        playbackSlider.value = '0';
        playbackSlider.max = '1';
        playbackTime.textContent = '0:00';
        setRangeFill(playbackSlider, 0, 1);
        return;
    }

    const position = isSeeking ? Number(playbackSlider.value) : getPlayerPosition();
    const duration = youtubePlayerReady && youtubePlayer
        ? Number(youtubePlayer.getDuration()) || 0
        : 0;

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
    const hasYouTube = activeRadioState
        && activeRadioState.source === 'youtube'
        && activeRadioState.videoId;

    if (!hasYouTube) {
        trackTitle.textContent = 'No source selected';
        trackSource.textContent = 'Choose a YouTube source below';
        setPlaying(false);
        setPlaybackStatus('SYSTEM READY');
        updatePlaybackDisplay();
        return;
    }

    const playbackState = activeRadioState.playing ? 'PLAYING' : 'PAUSED';
    const position = getPlayerPosition();

    updateVideoMetadata();
    trackTitle.textContent = currentTitle || activeRadioState.videoId;
    trackSource.textContent = `YouTube • ${playbackState} • ${formatTime(position)} • ${activeRadioState.volume}%`;
    setPlaying(activeRadioState.playing && !autoplayBlocked);
    setPlaybackStatus(playbackState);
    updatePlaybackDisplay();
}

function checkPlaybackDrift() {
    if (!activeRadioState
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
        cancelPreparedPlayback();
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

document.querySelectorAll('.tab-button').forEach((button) => {
    button.addEventListener('click', () => selectTab(button.dataset.tab));
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
        cancelPreparedPlayback();
    }
});

streamForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    await postNUI('playStream');
    setStatus('STREAMS NOT AVAILABLE YET', true, 5000);
});

playPauseButton.addEventListener('click', async () => {
    if (!activeRadioState || activeRadioState.source !== 'youtube') {
        setStatus('NO YOUTUBE SOURCE', true, 3000);
        return;
    }

    if (autoplayBlocked && activeRadioState.playing) {
        autoplayBlocked = false;
        playPauseButton.disabled = !canControl;
        resumeYouTube(localEffectiveVolume);
        setStatus('RETRYING PLAYBACK', false, 3000);
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
    updateVolumeDisplay();
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
