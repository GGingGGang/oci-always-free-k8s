# Monitoring

관측 구성은 서비스별 하위 폴더로 관리한다. 모두 `monitoring` 네임스페이스를 사용한다.

| 폴더 | 구성 | Argo CD Application |
| --- | --- | --- |
| [kps/](kps/README.md) | Prometheus, Alertmanager, 메트릭 수집, Discord 알림 설정 | `kps`, `monitoring-resources`, `monitoring-httproute` |
| [loki/](loki/README.md) | 단일 인스턴스 로그 저장소, 기존 PVC의 `loki/` subPath | `loki` |
| [tempo/](tempo/README.md) | 단일 인스턴스 트레이스 저장소, 기존 PVC의 `tempo/` subPath, 24h 보존 | `tempo` |
| [alloy/](alloy/README.md) | 앱 namespace 6개의 stdout/stderr를 API로 수집하여 Loki로 전송 | `alloy` |

Alloy는 Loki·Tempo Ready 확인 후 수동 동기화한다. 로그는 `app`, `web`, `auth`, `core`, `batch`, `notify`만 수집하며 namespace별 읽기 권한을 사용한다. 앱의 OTLP 트레이스는 4317(gRPC) / 4318(HTTP) 포트에서 받아 Tempo로 전달한다. Tempo는 별도 저장 경로 준비 후 수동 동기화하며 [설치·검증 절차](tempo/README.md)를 따른다.

최초 설치 시 `kps`를 먼저 동기화해 CRD를 설치하고, `monitoring-resources`로 AlertmanagerConfig를 적용한 뒤 `kps`를 다시 동기화한다. Discord 수신처는 별도 Secret이 필요하다. `monitoring`의 PSA baseline은 node-exporter 차트의 기본 hostPath를 금지하므로 예외가 없으면 Pod 생성이 거부될 수 있다. 상세 절차는 [KPS 안내](kps/README.md)를 따른다.

Prometheus의 50Gi PVC를 Loki와 Tempo가 각각 `loki/`, `tempo/` subPath로 공유한다. Prometheus의 `15d`/`45GiB`, Loki의 `72h`, Tempo의 `24h` 보존 설정은 용량 격리가 아니다. 기존 PVC가 연결된 노드 한 곳에만 `storage.ggang.cloud/observability=true` 라벨을 지정하고 각 저장 경로를 준비한다. Loki는 KPS 준비 후, Tempo는 자체 저장 경로 준비 후 동기화한다. 공유 디스크가 차면 모든 소비자에 영향을 준다.

`platform-root`는 [Application 정의](../argocd/apps/)를 자동 동기화하지만 `kps`, `monitoring-resources`, `monitoring-httproute`, `loki`, `tempo`, `alloy` 자체는 수동 동기화한다. 부모의 sync-wave는 자식 워크로드의 Ready를 보장하지 않으므로 각 단계의 준비 상태를 확인한다. 상세 절차와 검증은 각 폴더의 README를 따른다.
