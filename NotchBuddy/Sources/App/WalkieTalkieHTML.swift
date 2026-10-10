import Foundation

/// Production HTML for WalkieTalkieAudio WebRTC page
/// Shared between production (WalkieTalkieAudioImpl) and tests (WebKitBridgeTest)
let walkieTalkieHTML = """
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body>
<audio id="remoteAudio" autoplay></audio>
<script>
// Forward console errors to native logger
const originalConsoleError = console.error;
console.error = function(...args) {
    originalConsoleError.apply(console, args);
    window.webkit.messageHandlers.native.postMessage({
        type: 'consoleError',
        message: args.map(a => String(a)).join(' ')
    });
};

let pc = null;
let stream = null;
let audioTrack = null;
let wantMic = false;
let pendingCandidates = [];
let appliedCandidates = [];
let remoteDescriptionSet = false;
let audioCtx = null;
let localAnalyser = null;
let remoteAnalyser = null;
let levelTimer = null;
const remoteAudio = document.getElementById('remoteAudio');

if (!navigator.mediaDevices) {
    window.webkit.messageHandlers.native.postMessage({
        type: 'error',
        message: 'navigator.mediaDevices is undefined (secure context required)'
    });
}

function setMicEnabled(enabled) {
    wantMic = !!enabled;
    if (audioTrack) {
        audioTrack.enabled = wantMic;
    }
}

async function ensureStream() {
    if (!stream) {
        stream = await navigator.mediaDevices.getUserMedia({audio: true, video: false});
        audioTrack = stream.getAudioTracks()[0] || null;
        if (audioTrack) audioTrack.enabled = wantMic;
        attachAnalyser(stream, 'local');
    } else if (audioTrack) {
        audioTrack.enabled = wantMic;
    }
    return stream;
}

function attachAnalyser(mediaStream, kind) {
    try {
        if (!audioCtx) {
            audioCtx = new (window.AudioContext || window.webkitAudioContext)();
        }
        const src = audioCtx.createMediaStreamSource(mediaStream);
        const analyser = audioCtx.createAnalyser();
        analyser.fftSize = 256;
        analyser.smoothingTimeConstant = 0.55;
        src.connect(analyser);
        if (kind === 'local') localAnalyser = analyser;
        else remoteAnalyser = analyser;
        startLevelLoop();
    } catch (err) {
        console.error('analyser failed:', err);
    }
}

function rmsFromAnalyser(analyser) {
    if (!analyser) return 0;
    const buf = new Uint8Array(analyser.frequencyBinCount);
    analyser.getByteTimeDomainData(buf);
    let sum = 0;
    for (let i = 0; i < buf.length; i++) {
        const v = (buf[i] - 128) / 128;
        sum += v * v;
    }
    return Math.sqrt(sum / buf.length);
}

function startLevelLoop() {
    if (levelTimer) return;
    levelTimer = setInterval(() => {
        window.webkit.messageHandlers.native.postMessage({
            type: 'levels',
            local: rmsFromAnalyser(localAnalyser),
            remote: rmsFromAnalyser(remoteAnalyser)
        });
    }, 1000 / 15);
}

function stopLevelLoop() {
    if (levelTimer) {
        clearInterval(levelTimer);
        levelTimer = null;
    }
    localAnalyser = null;
    remoteAnalyser = null;
    if (audioCtx) {
        audioCtx.close();
        audioCtx = null;
    }
}

function wirePeerConnection() {
    pc.ontrack = (e) => {
        if (e.streams && e.streams[0]) {
            remoteAudio.srcObject = e.streams[0];
            remoteAudio.play().catch(err => console.error('Audio play failed:', err));
            attachAnalyser(e.streams[0], 'remote');
        }
    };

    pc.onconnectionstatechange = () => {
        window.webkit.messageHandlers.native.postMessage({
            type: 'connectionState',
            state: pc.connectionState
        });
    };

    pc.oniceconnectionstatechange = () => {
        window.webkit.messageHandlers.native.postMessage({
            type: 'iceState',
            state: pc.iceConnectionState
        });
        if (pc.iceConnectionState === 'connected') {
            pc.getStats().then(stats => {
                stats.forEach(report => {
                    if (report.type === 'candidate-pair' && report.state === 'succeeded') {
                        let localCandidate = null;
                        let remoteCandidate = null;
                        stats.forEach(r => {
                            if (r.type === 'local-candidate' && r.id === report.localCandidateId) {
                                localCandidate = r;
                            }
                            if (r.type === 'remote-candidate' && r.id === report.remoteCandidateId) {
                                remoteCandidate = r;
                            }
                        });
                        const candidateType = localCandidate ? localCandidate.candidateType : 'unknown';
                        window.webkit.messageHandlers.native.postMessage({
                            type: 'candidatePair',
                            candidateType: candidateType
                        });
                    }
                });
            }).catch(err => console.error('getStats failed:', err));
        }
    };

    pc.onicecandidate = (e) => {
        if (e.candidate) {
            window.webkit.messageHandlers.native.postMessage({
                type: 'ice',
                candidate: JSON.stringify(e.candidate.toJSON())
            });
        }
    };
}

async function createOffer(iceServers) {
    await ensureStream();

    pc = new RTCPeerConnection({iceServers: iceServers});
    remoteDescriptionSet = false;
    stream.getTracks().forEach(track => pc.addTrack(track, stream));
    wirePeerConnection();

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    return JSON.stringify(offer);
}

async function handleOffer(offerJSON, iceServers) {
    await ensureStream();

    pc = new RTCPeerConnection({iceServers: iceServers});
    remoteDescriptionSet = false;
    stream.getTracks().forEach(track => pc.addTrack(track, stream));
    wirePeerConnection();

    const offer = JSON.parse(offerJSON);
    await pc.setRemoteDescription(offer);
    remoteDescriptionSet = true;
    await flushPendingCandidates();
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return JSON.stringify(answer);
}

async function handleAnswer(answerJSON) {
    if (!pc) return;
    const answer = JSON.parse(answerJSON);
    await pc.setRemoteDescription(answer);
    remoteDescriptionSet = true;
    await flushPendingCandidates();
}

async function addIceCandidate(candidateJSON) {
    if (!pc || !remoteDescriptionSet) {
        pendingCandidates.push(candidateJSON);
        return;
    }
    const candidate = JSON.parse(candidateJSON);
    await pc.addIceCandidate(candidate);
    appliedCandidates.push(candidateJSON);
}

async function flushPendingCandidates() {
    const queued = pendingCandidates.splice(0, pendingCandidates.length);
    for (const candidateJSON of queued) {
        try {
            await pc.addIceCandidate(JSON.parse(candidateJSON));
        } catch (err) {
            console.error('addIceCandidate failed:', err);
        }
        appliedCandidates.push(candidateJSON);
    }
}

function getIceQueueStats() {
    return { pending: pendingCandidates.length, applied: appliedCandidates.length };
}

function cleanup() {
    stopLevelLoop();
    pendingCandidates = [];
    appliedCandidates = [];
    remoteDescriptionSet = false;
    if (pc) {
        pc.close();
        pc = null;
    }
    if (stream) {
        stream.getTracks().forEach(track => track.stop());
        stream = null;
        audioTrack = null;
    }
    if (remoteAudio.srcObject) {
        remoteAudio.srcObject.getTracks().forEach(track => track.stop());
        remoteAudio.srcObject = null;
    }
}
</script>
</body>
</html>
"""
