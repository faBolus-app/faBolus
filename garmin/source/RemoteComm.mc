using Toybox.Communications as Comm;
using Toybox.Lang;
using Toybox.System;

// Phone↔remote command builder + transport. Mirrors ../Shared/RemoteCommand.swift and
// schema/command.schema.json (version 1). Commands are sent to the iPhone host over the
// Connect IQ mobile SDK; the phone runs the confirm interlock and dispatches via PumpX2Kit.
module RemoteComm {
    const SCHEMA_VERSION = 1;

    // Builds a units-only bolus request dictionary matching the schema.
    function bolusRequest(units as Lang.Float, requestId as Lang.String) as Lang.Dictionary {
        return {
            "version" => SCHEMA_VERSION,
            "kind" => "bolusRequest",
            "requestId" => requestId,
            "units" => units
        };
    }

    function cancelBolus(requestId as Lang.String) as Lang.Dictionary {
        return { "version" => SCHEMA_VERSION, "kind" => "cancelBolus", "requestId" => requestId };
    }

    function statusRead(requestId as Lang.String) as Lang.Dictionary {
        return { "version" => SCHEMA_VERSION, "kind" => "statusRead", "requestId" => requestId };
    }

    // True when the companion phone is reachable.
    function phoneReachable() as Lang.Boolean {
        return System.getDeviceSettings().phoneConnected;
    }

    // Sends a command dictionary to the paired phone app. No-ops safely offline; never crashes.
    function send(cmd as Lang.Dictionary) as Void {
        if (!phoneReachable()) { return; }
        try {
            Comm.transmit(cmd, null, new CommListener());
        } catch (e) {
            // swallow transport errors; the UI reflects reachability separately
        }
    }

    var _counter = 0;
    function newRequestId() as Lang.String {
        _counter += 1;
        return System.getTimer().toString() + "-" + _counter.toString();
    }
}

// Minimal ConnectionListener (transmit requires one). Delivery status comes back via the
// separate phone→watch bolusStatus message, so these are no-ops.
class CommListener extends Comm.ConnectionListener {
    function initialize() { ConnectionListener.initialize(); }
    function onComplete() as Void {}
    function onError() as Void {}
}
