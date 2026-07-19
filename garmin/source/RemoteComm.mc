using Toybox.Communications as Comm;
using Toybox.Lang;

// Phone↔remote command builder + transport. Mirrors ../Shared/RemoteCommand.swift and
// schema/command.schema.json (version 1). Commands are sent to the iPhone host over the
// Connect IQ mobile SDK; the phone runs the confirm interlock and dispatches via PumpX2Kit.
module RemoteComm {
    const SCHEMA_VERSION = 1;

    // Builds a units-only bolus request dictionary matching the schema.
    function bolusRequest(units, requestId) {
        return {
            "version" => SCHEMA_VERSION,
            "kind" => "bolusRequest",
            "requestId" => requestId,
            "units" => units
        };
    }

    function cancelBolus(requestId) {
        return { "version" => SCHEMA_VERSION, "kind" => "cancelBolus", "requestId" => requestId };
    }

    function statusRead(requestId) {
        return { "version" => SCHEMA_VERSION, "kind" => "statusRead", "requestId" => requestId };
    }

    // Sends a command dictionary to the paired phone app (Connect IQ mobile SDK). Phone-app
    // transmits take null options.
    function send(cmd, listener) {
        Comm.transmit(cmd, null, listener);
    }

    // Generates a simple unique request id (uptime millis + counter).
    var _counter = 0;
    function newRequestId() {
        _counter += 1;
        return Toybox.System.getTimer().toString() + "-" + _counter.toString();
    }
}
