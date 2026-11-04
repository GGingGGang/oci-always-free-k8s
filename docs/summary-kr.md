# Oracle Cloud Infrastructure Always Free 리소스 요약

일부 리소스의 요약이다. 이 프로젝트의 PAYG 계정에는 A1 워커 4 OCPU / 24 GB 무료 조건이 적용되며 다른 계정에는 해당 계정의 조건이 적용된다. 배포 전에 [Oracle Always Free 문서](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)와 테넌트 한도를 확인한다.

## Compute
| Resource | 설명 | Always Free 한도 |
| :--- | :--- | :--- |
| AMD Compute Instance | AMD 기반 컴퓨팅 VM (1/8 OCPU, 1GB RAM) | 2개 VM |
| ARM Compute Instance | Arm 기반 Ampere A1 VM 인스턴스 | 월 1,500 OCPU 시간 & 9,000 GB 시간; Always Free 테넌트는 홈 리전 합계 2 OCPU / 12 GB |

## Developer Services
| Resource | 설명 | Always Free 한도 |
| :--- | :--- | :--- |
| APEX | Low-code 애플리케이션 개발 플랫폼 | Always Free Autonomous Database 2개에 포함 |

## Networking
| Resource | 설명 | Always Free 한도 |
| :--- | :--- | :--- |
| Flexible Network Load Balancer | Layer 3/4 트래픽 분산 | 1개 인스턴스 |
| Load Balancer | 고가용성 로드밸런서 (프로비저닝된 대역폭) | 1개 인스턴스, 10 Mbps; 2020-12-15 이후 생성 테넌트는 Flexible, 이전은 Micro |
| Outbound Data Transfer | 인터넷 방향 이그레스 트래픽 (Internet Gateway, NAT Gateway, Load Balancer 응답 포함). VCN 내부 트래픽 및 Service Gateway 경유 OCI 내부 트래픽은 제외 | 월 10TB |
| Service Connector Hub | OCI 서비스 간 데이터 이동을 위한 메시지 버스 | 무료·체험 계정: 2개 커넥터; 유료 계정: 서비스 한도 확인 |
| Site-to-Site VPN | 온프레미스와 VCN 간 IPSec 연결 | Free Tier 계정: 최대 50개 IPSec 연결 |
| VCN Flow Logs | 트래픽 감사 및 문제 해결을 위한 트래픽 상세 정보 | Free Tier 테넌트: Logging과 공유하여 월 최대 10GB |
| Virtual Cloud Networks (VCN) | IPv4/IPv6 지원 소프트웨어 정의 네트워크 | Free Tier 테넌트: 최대 2개 VCN |

## Observability and Management
| Resource | 설명 | Always Free 한도 |
| :--- | :--- | :--- |
| Application Performance Monitoring | 애플리케이션 모니터링 및 진단 | 시간당 1,000 트레이싱 이벤트 & 10회 신서틱 실행 |
| Email Delivery | 고용량 이메일 관리 솔루션 | 월 3,000개 이메일 발송 |
| Logging | 모든 로그를 위한 통합 대시보드 | Free Tier 테넌트: VCN Flow Logs와 공유하여 월 최대 10GB |
| Monitoring | 메트릭 조회 및 알람 관리 | 5억 건 수집 & 10억 건 조회 데이터 포인트 |
| Notification | 이메일, SMS, HTTPS를 통한 알림 | 월 1M HTTPS & 1,000 이메일 메시지 |

## Oracle Databases
| Resource | 설명 | Always Free 한도 |
| :--- | :--- | :--- |
| Autonomous Database | ATP, ADW, AJD 또는 APEX 개발 | 합계 2개 데이터베이스 |
| HeatWave | 트랜잭션 및 분석용 통합 AI/ML | 홈 리전 MySQL.Free DB 시스템 1개: 데이터/로그 50 GiB, 자동 백업 1일 보존 |
| NoSQL Database | 완전 관리형 NoSQL 데이터베이스 서비스 | 월 읽기 1억 3,300만 건 및 쓰기 1억 3,300만 건, 테이블당 25GB (최대 3개); Phoenix 리전 한정 |

## Security
| Resource | 설명 | Always Free 한도 |
| :--- | :--- | :--- |
| Bastions | 프라이빗 대상으로의 제한된 SSH 접근 | 무료 서비스; 테넌트 서비스 한도 확인 |
| Certificates | 인증서 발급 및 관리 | 5개 Private CA & 150개 Private TLS 인증서 |
| Vault | 마스터 암호화 키 및 시크릿 관리 | 소프트웨어 보호 키 무료; HSM 키 버전 20개 & Vault 시크릿 150개 |

## Storage
| Resource | 설명 | Always Free 한도 |
| :--- | :--- | :--- |
| Archive Storage | 비정형 아카이브 스토리지 | 아래 Object Storage 계층 참조 |
| Block Volume Storage | 부트 및 블록 볼륨 스토리지 | 홈 리전 부트/블록 합계 200GB; 볼륨 백업 5개 |
| Object Storage | Object Storage API 요청 | 월 50,000 API 요청 |
| Object Storage - Infrequent Access | 비정형 저주기 접근 스토리지 | 아래 Object Storage 계층 참조 |
| Object Storage - Standard | 비정형 표준 스토리지 | Always Free 전용: 계층 합계 20GB; 유료 또는 크레딧이 남은 체험 계정: 계층당 10GB |

## Others
| Resource | 설명 | Always Free 한도 |
| :--- | :--- | :--- |
| Console Dashboards | OCI 리소스 모니터링용 커스텀 대시보드 | 최대 100개 대시보드 |

---

## Effectively Free — 공식 Always Free 목록에는 없지만 무료로 사용 가능한 리소스

공식 Always Free 목록에 포함되지 않지만, 기존 Always Free 리소스를 활용하거나 서비스 자체가 무료라서 **실질적으로 무료로 사용 가능한** 리소스입니다.

| Resource | 설명 | 무료 조건 | 주의사항 |
| :--- | :--- | :--- | :--- |
| OKE Basic Cluster | Oracle 관리형 Kubernetes 컨트롤 플레인 | 컨트롤 플레인은 무료; 워커, 스토리지, 네트워크 사용량은 과금될 수 있음 | 유료 계정 필요. Virtual Node와 컨트롤 플레인 SLA 미지원; 필수 add-on은 배포되지만 사용자 지정은 유지가 보장되지 않음 |
| Internet Gateway | VCN에서 인터넷으로의 직접 연결 게이트웨이 | 게이트웨이 자체 무료. 아웃바운드 트래픽은 월 10TB까지 무료 | 10TB 초과 시 데이터 전송 요금 발생 |
| NAT Gateway | 공인 IP 없는 리소스의 아웃바운드 인터넷 접근 | 게이트웨이 자체 무료. 아웃바운드 트래픽은 월 10TB까지 무료 | 10TB 초과 시 데이터 전송 요금 발생 |
| Service Gateway | VCN 내부에서 OCI 서비스(Object Storage 등)로의 프라이빗 접근 | **추가 요금 없음** (Oracle 공식 제품 페이지 명시). 인터넷/NAT 게이트웨이 없이 OCI 내부 서비스로 안전하게 접근 가능 | 공식 Always Free 목록에는 미등재. 단, Oracle이 "no additional cost"로 공식 명시 |

> **참고**: Compute와 Container Instances는 A1 리소스 쿼터를 공유하지만, 이 사실만으로 동일한 무료 사용량이 적용되는 것은 아니다. 요금과 테넌트 한도를 확인한다.
