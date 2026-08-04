# Validate on-premises connectivity from classic compute.
#
# Run this in a notebook attached to a CLASSIC cluster in the spoke workspace. Serverless compute runs outside the
# injected VNet and does not receive the hub gateway's propagated routes, so a result from serverless says nothing
# about this path.
#
# Set target_ip to a host reachable through the hub's VPN gateway. When testing with a point-to-site VPN client, use
# the address assigned to the client from the gateway's client address pool - not the client's address on its own local
# network, which is not advertised to Azure unless a site-to-site connection carries that range.
#
# Interpreting the result:
#   SUCCESS  - the route and the listener are both working
#   REFUSED  - routing works; nothing is listening on that port
#   TIMEOUT  - packets left the VNet but got no response; check the hub peering and gateway
#   ERROR: [Errno 113] No route to host - no usable route; check that the hub peering is Connected and that the
#          hub side sets allow_gateway_transit
import socket

target_ip = "<TARGET_IP>"  # e.g. the P2S client address of the host you are testing against
target_port = 4533

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)

try:
    s.connect((target_ip, target_port))
    print(f"SUCCESS: Connected to {target_ip}:{target_port}")
    s.close()
except socket.timeout:
    print(f"TIMEOUT: No response from {target_ip}. Check the hub peering and gateway configuration.")
except ConnectionRefusedError:
    print(f"REFUSED: Reached {target_ip}, but nothing is listening on port {target_port}.")
except Exception as e:
    print(f"ERROR: {e}")
