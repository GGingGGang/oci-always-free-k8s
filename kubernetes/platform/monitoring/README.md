# Monitoring

관측 구성은 서비스별 하위 폴더로 관리한다. 모두 `monitoring` 네임스페이스를 사용한다.

| 폴더 | 구성 | Argo CD Application |
| --- | --- | --- |
| [kps/](kps/README.md) | Prometheus, Alertmanager, 메트릭 수집, 알림 설정 | `kps`, `monitoring-resources`, `monitoring-httproute` |
| [loki/](loki/README.md) | 단일 인스턴스 로그 저장소, 기존 PVC의 `loki/` subPath | `loki` |

Loki 설치 시 기존 Prometheus PVC의 경로·권한과 노드 라벨을 준비한 뒤 KPS, Loki 순서로 수동 동기화한다. 상세 절차와 검증은 각 폴더의 README를 따른다.

폴더 이동과 함께 [Application 정의](../argocd/apps/)의 소스 경로도 반영해야 한다. `platform-root`가 새 경로를 반영한 것을 확인한 뒤 자식 앱을 동기화한다. Application·Helm release·namespace·PVC 이름은 유지한다.
