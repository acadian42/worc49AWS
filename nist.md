
**The Argument in Brief:**
Bypassing Zscaler to expose a user’s "Public ISP IP" for authentication violates modern Zero Trust principles. It trades high-value security (inspection) for low-value visibility (network location). Leading authorities define "Network Location" (IP address) as the weakest form of trust.

---

### **Industry Best Practices: Why "Real IP" Visibility is a Security Regression**

#### **1. NIST: Network Location is Not a Trust Metric**

The National Institute of Standards and Technology (NIST) defines the US government's standard for Zero Trust. Their core publication explicitly states that relying on the network (IP address) for trust is a failure of architecture.

* **The Standard:** *NIST Special Publication 800-207 (Zero Trust Architecture)*
* **The Quote:** "Zero trust assumes there is **no implicit trust granted to assets or user accounts based solely on their physical or network location**... Access to individual enterprise resources is granted on a per-session basis."
* **Why it supports you:** NIST argues that knowing a user is coming from "IP Address X" (even a residential ISP) proves nothing about the user's intent or device health. Bypassing inspection to get this weak signal violates Tenet 1 of Zero Trust.

#### **2. CISA: Moving From "Traditional" to "Optimal"**

The Cybersecurity and Infrastructure Security Agency (CISA) Maturity Model explicitly grades "IP-based controls" as "Traditional" (the lowest tier of maturity).

* **The Standard:** *CISA Zero Trust Maturity Model (Version 2.0)*
* **The Guidance:** The model outlines a shift from "Location-centric" (allowing access based on IP/VPN) to "Identity- and Device-centric."
* **Why it supports you:** Capturing the public IP forces you to write policies based on "Location." CISA states you should be writing policies based on "Device Health" (which requires the Zscaler agent to remain inline).

#### **3. Gartner: ZTNA Replaces IP Allowlisting**

Gartner defines Zero Trust Network Access (ZTNA) specifically as a tool to *hide* applications from the public internet, not to expose users' public IPs to them.

* **The Standard:** *Market Guide for Zero Trust Network Access (ZTNA)*
* **The Logic:** ZTNA creates a logical-access boundary based on identity and context, *not* network IP. It recommends a "default deny" posture where the user's actual network location is irrelevant, provided their context (identity + device) is verified.
* **Why it supports you:** Gartner advises against architectures that rely on "allowlisting" IPs, as this creates a brittle security posture that cannot scale with a remote workforce.

---

### **The "Inspection vs. Visibility" Trade-off**

Bypassing Zscaler to see the "Real IP" creates a **Security Gap** that third-party experts warn against:

1. **Loss of Threat Prevention:** If traffic goes direct-to-internet to show the "Real IP," it bypasses the Secure Web Gateway (SWG). You lose SSL inspection, meaning you cannot detect Phishing tokens or Malware delivery in that session.
2. **The "Allowlist" Fallacy:** Security.com notes that IP allowlisting is "static by design." If a user's home ISP IP changes (dynamic DNS), they are locked out. If you allowlist large ranges of ISP IPs, you open the door to attackers using that same ISP.
3. **Spoofing Risks:** Attackers can easily spoof IP addresses or route attacks through residential proxies. Relying on the "Public IP" for security is "security theater."

### **Recommended Reference Links**

* **NIST SP 800-207 (The "Bible" of Zero Trust):**
* *Link:* [NIST.gov - Zero Trust Architecture](https://nvlpubs.nist.gov/nistpubs/specialpublications/NIST.SP.800-207.pdf)
* *Key Takeaway:* "Zero trust assumes there is no implicit trust granted to assets... based solely on their network location."


* **CISA Zero Trust Maturity Model:**
* *Link:* [CISA.gov - Zero Trust Maturity Model](https://www.cisa.gov/zero-trust-maturity-model)
* *Key Takeaway:* Moving from "Traditional" (Static network/IP rules) to "Optimal" (Continuous validation).


* **Gartner Market Guide for ZTNA:**
* *Link:* [Gartner - Zero Trust Network Access Strategy](https://www.gartner.com/en/cybersecurity/topics/zero-trust-architecture)
* *Key Takeaway:* Zero Trust should focus on "Identity of users and devices," not network perimeters.



### **Summary for Management**

*"Bypassing our security controls to capture a user's Public IP is an architectural regression. NIST, CISA, and Gartner all explicitly advise against using 'Network Location' (IP) as a trust signal. We should maintain Zscaler visibility (Inspection) and use **Device Posture** (Intune/ZCC) as our verification method, which is the industry standard for Zero Trust."*
