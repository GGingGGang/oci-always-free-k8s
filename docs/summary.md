# Oracle Cloud Infrastructure Always Free Resources Summary

Selected resources; the project PAYG account has a free allowance of 4 OCPU / 24 GB for A1 workers. Eligibility and allowances for other accounts depend on their terms. Check the [Oracle Always Free documentation](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) and your tenancy before deployment.

## Compute
| Resource | Description | Always Free Limit |
| :--- | :--- | :--- |
| AMD Compute Instance | AMD based Compute VMs (1/8 OCPU, 1 GB RAM) | 2 VMs |
| ARM Compute Instance | Arm-based Ampere A1 VM instances | 1,500 OCPU hours & 9,000 GB hours/month; Always Free tenancies: 2 OCPU / 12 GB total in home region |

## Developer Services
| Resource | Description | Always Free Limit |
| :--- | :--- | :--- |
| APEX | Low-code application development platform | Included in the two Always Free Autonomous Databases |

## Networking
| Resource | Description | Always Free Limit |
| :--- | :--- | :--- |
| Flexible Network Load Balancer | Layer 3/Layer 4 traffic distribution | 1 instance |
| Load Balancer | Highly available load balancers with provisioned bandwidth | 1 instance, 10 Mbps; Flexible for tenancies created on or after 2020-12-15, Micro for earlier tenancies |
| Outbound Data Transfer | Egress traffic to the internet via Internet Gateway, NAT Gateway, and Load Balancer responses. Excludes intra-VCN traffic and OCI-internal traffic routed through Service Gateway | Up to 10 TB per month |
| Service Connector Hub | Message bus for data movement between OCI services | Free and trial accounts: 2 connectors; paid accounts: check service limits |
| Site-to-Site VPN | IPSec connection between on-premises and VCN | Free Tier account: up to 50 IPSec connections |
| VCN Flow Logs | Traffic details for auditing and troubleshooting | Free Tier tenancy: up to 10 GB per month shared with Logging |
| Virtual Cloud Networks (VCN) | Software-defined network with IPv4/IPv6 support | Free Tier tenancy: up to 2 VCNs |

## Observability and Management
| Resource | Description | Always Free Limit |
| :--- | :--- | :--- |
| Application Performance Monitoring | Application monitoring and diagnostics | 1,000 tracing events & 10 Synthetic runs/hour |
| Email Delivery | Managed solution for high-volume emails | Up to 3,000 emails sent per month |
| Logging | Scalable single pane of glass for all logs | Free Tier tenancy: up to 10 GB per month shared with VCN Flow Logs |
| Monitoring | Query metrics and manage alarms | 500M ingestion & 1B retrieval datapoints |
| Notification | Alerting via email, text (SMS), and HTTPS | 1M HTTPS & 1,000 email messages/month |

## Oracle Databases
| Resource | Description | Always Free Limit |
| :--- | :--- | :--- |
| Autonomous Database | ATP, ADW, AJD, or APEX Development | 2 databases total |
| HeatWave | Integrated AI/ML for transactions and analytics | 1 MySQL.Free DB system in home region: 50 GiB data/log storage, 1-day automatic backup |
| NoSQL Database | Fully managed NoSQL database service | 133M reads and 133M writes per month, 25GB/table (up to 3 tables); Phoenix region only |

## Security
| Resource | Description | Always Free Limit |
| :--- | :--- | :--- |
| Bastions | Restricted SSH access to private targets | Free service; check tenancy service limits |
| Certificates | Certificate issuance and management | 5 Private CA & 150 private TLS certificates |
| Vault | Master encryption keys and secrets management | Software-protected keys free; 20 HSM key versions & 150 Vault secrets |

## Storage
| Resource | Description | Always Free Limit |
| :--- | :--- | :--- |
| Archive Storage | Unstructured archive storage | See Object Storage tiers below |
| Block Volume Storage | Boot and block volume storage | 200 GB combined boot/block storage in home region; 5 volume backups |
| Object Storage | API requests for object storage | Up to 50,000 API requests per month |
| Object Storage - Infrequent Access | Unstructured infrequent access storage | See Object Storage tiers below |
| Object Storage - Standard | Unstructured standard storage | Always Free-only: 20 GB shared across tiers; paid or trial with credits: 10 GB per tier |

## Others
| Resource | Description | Always Free Limit |
| :--- | :--- | :--- |
| Console Dashboards | Custom dashboards for monitoring OCI resources | Up to 100 dashboards |

---

## Effectively Free — Not in the Official Always Free List

Resources not listed in the official Always Free catalog, but usable at no cost by leveraging existing Always Free resources or because the service itself carries no charge.

| Resource | Description | Why It's Free | Notes |
| :--- | :--- | :--- | :--- |
| OKE Basic Cluster (Container Engine for Kubernetes) | Oracle-managed Kubernetes control plane | Control plane is free; worker, storage and network usage may incur charges | Requires a paid account. Virtual nodes and control plane SLA are not supported; essential add-ons are deployed but customizations may not persist |
| Internet Gateway | Direct connectivity between a VCN and the internet | Gateway itself is free. Outbound traffic is free up to 10 TB/month | Data transfer charges apply beyond the 10 TB threshold |
| NAT Gateway | Outbound internet access for resources without a public IP | Gateway itself is free. Outbound traffic is free up to 10 TB/month | Data transfer charges apply beyond the 10 TB threshold |
| Service Gateway | Private access to OCI services (e.g. Object Storage) from within a VCN | **No additional cost** (explicitly stated on Oracle's product page). Enables secure access to OCI-internal services without traversing the internet | Not listed in the official Always Free catalog, but Oracle explicitly states "no additional cost" |

> **Note**: Compute and Container Instances share an A1 resource quota; this does not establish that both qualify for the same free usage allowance. Verify pricing and tenancy limits.

