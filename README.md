<div align="center">

<h1>EchoLink Control Server Using Headscale</h1>

</div>

> **Note:** This is a fork of [juanfont/headscale](https://github.com/juanfont/headscale). 

This repository serves as the centralized control plane for **[EchoLink](https://github.com/uganthan2005/EchoLink)**—a secure, SSH-based device-to-device connectivity app. 

While the core functionality remains upstream Headscale, this fork is maintained to track the specific configurations, deployment scripts, and strict ACL policies required for the EchoLink backend. 

### Role in EchoLink:
* **Mesh Coordination:** Issues stable, private tailnet IPs (`100.64.x.x`) to EchoLink clients (Windows, Linux, Android) via bundled `tailscaled` nodes.
* **Tenant Isolation:** Enforces strict Access Control Lists (ACLs) to ensure devices can only communicate within their own user account.
* **Security Guardrails:** Restricts all device-to-device tailnet traffic exclusively to SSH (Port 22), blocking unauthorized ports.
* **NAT Traversal:** Provides DERP relay configuration for seamless peer-to-peer connectivity across restrictive networks.

To see the client app that interacts with this server, visit the main **[EchoLink Repository](https://github.com/uganthan2005/EchoLink)**.
