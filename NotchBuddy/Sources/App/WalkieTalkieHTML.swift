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
let pc = null;
let stream = null;
let audioTrack = null;
let wantMic = false;
const remoteAudio = document.getElementById('remoteAudio');

if (!navigator.mediaDevices) {
    window.webkit.messageHandlers.native.postMessage({
        type: 'error',
        message: 'navigator.mediaDevices is undefined (secure context required)'
    });
}

async function createOffer(iceServers) {
    if (!stream) {
        stream = await navigator.mediaDevices.getUserMedia({audio: true, video: false});
        audioTrack = stream.getAudioTracks()[0];
        audioTrack.enabled = wantMic;
    }
    
    pc = new RTCPeerConnection({iceServers: iceServers});
    stream.getTracks().forEach(track => pc.addTrack(track, stream));
    
    pc.ontrack = (e) => {
        if (e.streams && e.streams[0]) {
            remoteAudio.srcObject = e.streams[0];
            remoteAudio.play().catch(err => console.error('Audio play failed:', err));
        }
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
    
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    return JSON.stringify(offer);
}

async function handleOffer(offerJSON, iceServers) {
    if (!stream) {
        stream = await navigator.mediaDevices.getUserMedia({audio: true, video: false});
        audioTrack = stream.getAudioTracks()[0];
        audioTrack.enabled = wantMic;
    }
    
    pc = new RTCPeerConnection({iceServers: iceServers});
    stream.getTracks().forEach(track => pc.addTrack(track, stream));
    
    pc.ontrack = (e) => {
        if (e.streams && e.streams[0]) {
            remoteAudio.srcObject = e.streams[0];
            remoteAudio.play().catch(err => console.error('Audio play failed:', err));
        }
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
    
    const offer = JSON.parse(offerJSON);
    await pc.setRemoteDescription(offer);
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return JSON.stringify(answer);
}

async function handleAnswer(answerJSON) {
    if (!pc) return;
    const answer = JSON.parse(answerJSON);
    await pc.setRemoteDescription(answer);
}

async function addIceCandidate(candidateJSON) {
    if (!pc) return;
    const candidate = JSON.parse(candidateJSON);
    await pc.addIceCandidate(candidate);
}

function setMicEnabled(enabled) {
    wantMic = enabled;
    if (audioTrack) {
        audioTrack.enabled = enabled;
    }
}

function cleanup() {
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
