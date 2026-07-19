using Toybox.System;
using Toybox.Background;
using Toybox.Communications as Comm;
using Toybox.Lang;

// Background service that refreshes the BG complication while the app is closed. On each
// temporal event it re-publishes the last-known reading (so a newly-added complication isn't
// blank), then asks the phone for a fresh status; when the phone replies it publishes the new
// value directly and exits. If the phone is unreachable it just exits — the persisted value
// stays on the face. Bench PoC: background phone reachability varies, so this is best-effort;
// foreground opens/glances remain the reliable refresh path.
(:background)
class BgServiceDelegate extends System.ServiceDelegate {
    function initialize() { ServiceDelegate.initialize(); }

    function onTemporalEvent() as Void {
        BgComplication.publish(null, null, 0);   // keep last-known reading visible (or "--" if stale)

        if (System.getDeviceSettings().phoneConnected) {
            Comm.registerForPhoneAppMessages(method(:onPhoneMessage));
            try {
                Comm.transmit(RemoteComm.statusRead(RemoteComm.newRequestId()), null, new BgCommListener());
                return;   // wait for the reply; the system bounds our runtime
            } catch (e) {
                Background.exit(null);
            }
        } else {
            Background.exit(null);
        }
    }

    function onPhoneMessage(msg as Comm.PhoneAppMessage) as Void {
        var data = msg.data;
        if (data instanceof Lang.Dictionary) {
            AppState.handle(data as Lang.Dictionary);
            BgComplication.publishFromState();
        }
        Background.exit(null);
    }
}

(:background)
class BgCommListener extends Comm.ConnectionListener {
    function initialize() { ConnectionListener.initialize(); }
    function onComplete() as Void {}
    function onError() as Void { Background.exit(null); }
}
