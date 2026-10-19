# 0.10.7: bounded search expansion

The supplied Windows report showed a 3.1 Mbit/s proxy for an 18.2 Mbit/s
selection target and a quick queue of 1/6. Both modes now fill their native
queue from distinct candidates instead of reducing quick mode to the usable
proxy count. Same-source failures no longer veto other endpoints.

One invocation explores up to two quick rounds (four-minute overall budget)
or four deep rounds (twelve-minute overall budget), with up to six/eight native
attempts per round. Candidates submitted for proxy or tunnel tests are excluded
from subsequent rounds of the same invocation. Cross-invocation rotation remains.
Cancellation, route failures, network changes and unconfirmed teardown abort
expansion. Successful selection stops immediately under the existing quality rules.
Network/catalog operations retain their bounded deadlines; in-flight cleanup may
finish after the overall search budget expires.

For production engines requiring a speed goal, slow/unstable working tunnels
are no longer saved as final results or restored as finalists. Manual connection
remains available. Regression fixtures cover the reported 3.1 vs 18.2 Mbit case,
success in round four, distinct endpoints and queue filling.

Malformed URI ArgumentError is isolated per subscription line like FormatException.
This addresses a parser failure mode, not proof of the exact bad upstream record.
The supplied report does not contain evidence identifying the cause of the earlier
Windows disconnection. Android health monitoring remains Android-specific.
