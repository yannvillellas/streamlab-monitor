import Foundation

enum Fixture {

    static let joinedPeerNull = #"""
    {"type":"joined","peerId":"f43f04bd-b124-494f-962e-b75329d84d65","room":"studio-a","role":"sender","peer":null}
    """#

    static let joinedWithPeer = #"""
    {"type":"joined","peerId":"f43f04bd-b124-494f-962e-b75329d84d65","room":"studio-a","role":"viewer","peer":{"id":"9a8b7c6d-1111-2222-3333-444455556666","role":"sender"}}
    """#

    static let peerJoined = #"""
    {"type":"peer-joined","peer":{"id":"9a8b7c6d-1111-2222-3333-444455556666","role":"viewer"}}
    """#

    static let peerLeft = #"""
    {"type":"peer-left","peerId":"9a8b7c6d-1111-2222-3333-444455556666"}
    """#

    static let offer = #"""
    {"type":"offer","from":"9a8b7c6d-1111-2222-3333-444455556666","sdp":"v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n"}
    """#

    static let answer = #"""
    {"type":"answer","from":"9a8b7c6d-1111-2222-3333-444455556666","sdp":"v=0\r\no=- 7614219274584779017 2 IN IP4 127.0.0.1\r\n"}
    """#

    static let iceCandidate = #"""
    {"type":"ice-candidate","from":"9a8b7c6d-1111-2222-3333-444455556666","candidate":{"candidate":"candidate:842163049 1 udp 1677729535 192.0.2.4 54873 typ srflx","sdpMid":"0","sdpMLineIndex":0}}
    """#

    static let errorRoleTaken = #"""
    {"type":"error","code":"role-taken","message":"That role is already taken in this room."}
    """#

    static let errorInvalidMessage = #"""
    {"type":"error","code":"invalid-message","message":"Message must be valid JSON with a known type."}
    """#

    static let clientJoin = #"""
    {"type":"join","room":"studio-a","role":"viewer","sessionId":"session-1"}
    """#

    static let clientOffer = #"""
    {"type":"offer","sdp":"v=0\r\n"}
    """#

    static let clientAnswer = #"""
    {"type":"answer","sdp":"v=0\r\n"}
    """#

    static let clientIceCandidate = #"""
    {"type":"ice-candidate","candidate":{"candidate":"candidate:1 1 udp 1 192.0.2.4 5000 typ host","sdpMid":"0","sdpMLineIndex":0}}
    """#

    static let clientLeave = #"""
    {"type":"leave"}
    """#
}
