# Monitoring (kube-prometheus-stack)

메트릭/알림. Prometheus + Alertmanager + node-exporter + kube-state-metrics + prometheus-operator를 운영한다. `values.yaml`은 Grafana 비활성화를 선언하며 rollback을 위한 기존 설정 블록은 보존한다. Alertmanager 는 Discord 웹훅으로 배선됨 (AlertmanagerConfig CR — 절차·구조는 §2).

> 이 변경은 저장소의 준비본이며 아직 배포되지 않았다. `grafana.enabled: false`가 Helm 렌더에서 Grafana 리소스를 제외해도, 이미 클러스터에 있는 Grafana 워크로드는 Argo CD `kps` 앱을 prune 동기화하기 전까지 삭제되지 않는다 (§4).

참조:
- https://github.com/prometheus-community/helm-charts (chart `prometheus-community/kube-prometheus-stack`)
- https://kubernetes.io/docs/concepts/security/pod-security-standards/ (PSA baseline)

## 1. 전제 조건

- `monitoring` 네임스페이스 + PSA `enforce=baseline` (`../../../infra/namespaces/`)
- Grafana rollback 시에만 `grafana-admin-fixed` Secret (`monitoring` NS)이 필요하다. 현재 Grafana는 렌더되지 않으므로 이 Secret을 읽지 않는다 (§4).
- Helm 3.6+
- 권장 버전: 작성 시점 추론 `~75.0.0` — chart가 app 버전을 추종해 major를 자주 올림. 설치 전 확인:
  ```bash
  helm search repo prometheus-community/kube-prometheus-stack --versions | head
  ```

> `kubectl top` / CPU 기반 HPA 는 이 스택이 아니라 별도 **metrics-server**(`metrics.k8s.io`)가 필요. node-exporter ≠ metrics-server.

## 2. 설치

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --version "~75.0.0" -f values.yaml --wait

kubectl apply -f httproute.yaml
```

기존 운영 설치의 변경은 위 신규 설치 명령 대신 §4의 Argo CD 절차를 따른다. Grafana를 rollback으로 다시 활성화할 때 admin 자격은 `grafana.admin.existingSecret: grafana-admin-fixed` 로 고정한다 (`values.yaml`). 기존 Secret을 유지하며, 새 환경에서만 §5의 Secret 생성 절차를 사용한다. chart 는 `admin.existingSecret` 이 지정되면 자체 admin Secret 을 만들지 않고 이 Secret 을 `GF_SECURITY_ADMIN_USER/PASSWORD` 로 주입한다:

```bash
kubectl -n monitoring get secret grafana-admin-fixed \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo
# tailnet 경유 http://<grafana ClusterIP> → admin / <위 출력>  (public httproute 는 주석 처리)
```

### 알림 수신처 배선 (Discord)

Alertmanager 는 배선 전까지 수신처가 `"null"` 뿐 — 알림이 어디로도 발송되지 않는다. 라우팅/수신처는 **`alertmanager-config.yaml`(AlertmanagerConfig CR, git-가시)** 이 소유하고 `values.yaml` 의 `alertmanagerSpec.alertmanagerConfiguration` 이 참조한다(global 모드). 웹훅 URL 만 사전 수동 Secret 으로 분리 (`grafana-admin-fixed` 와 동일 패턴) — CR 의 `apiURL` 이 secretKeyRef 로 가리키고, operator 가 config 생성 시점에 값을 인라인하므로 파드 마운트 불요.

> chart `alertmanager.config` + `webhook_url_file` 방식은 불가 — AM 바이너리(v0.28)는 지원하지만 **prometheus-operator(v0.83) config 파서가 그 필드를 몰라** `-generated` Secret 생성을 거부한다. AlertmanagerConfig 는 operator 자기 CRD 라 이 파서 불일치가 구조적으로 없다. helm CLI 직접 upgrade 도 불가 — kps 는 ArgoCD 가 ServerSideApply 로 소유해 field manager 충돌로 거부된다 (`../../argocd/README.md` §6 adopt 구조).

global 모드는 차트 기본 config 를 **통째로 대체**한다 — kps 기본 inhibit 규칙과 Watchdog→null 라우트가 CR 에 명시적으로 들어가 있는 이유. info 알림은 InfoInhibitor 억제로 통지되지 않고 warning 이상만 도착한다.

① Discord 채널 → 설정 → 연동 → 웹훅 생성, URL 복사 — `https://discord.com/api/webhooks/<id>/<token>` 그대로 (접미사 불요).

② Secret 생성:

```bash
kubectl -n monitoring create secret generic discord-webhook \
  --from-literal=webhook-url='<DISCORD_WEBHOOK_URL>'
```

③ 적용 — push 후 sync (`monitoring-resources` 앱이 CR 을, `kps` 앱이 values 참조를 배포. syncPolicy 에 automated 없음 — push 만으로는 반영되지 않는다):

```bash
kubectl -n cicd patch application platform-root --type merge -p '{"operation":{"sync":{}}}'
kubectl -n cicd patch application monitoring-resources --type merge -p '{"operation":{"sync":{}}}'
kubectl -n cicd patch application kps --type merge -p '{"operation":{"sync":{}}}'
```

④ 시험 발사 + 검증:

```bash
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-alertmanager 9093 &
curl -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
  "labels": {"alertname": "WiringTest", "severity": "warning"},
  "annotations": {"summary": "receiver wiring smoke test"}
}]'
# → Discord 도착 확인. 발송 실패는 메트릭으로 상시 감시 가능:
#   alertmanager_notifications_failed_total{integration="discord"}
```

## 3. 검증

```bash
kubectl get pods -n monitoring

kubectl -n monitoring get prometheus,alertmanager
kubectl -n monitoring get pvc
```

Prometheus 타겟 (전부 up, control-plane `down` 타겟 없어야 함):

```bash
kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/targets
```

## 4. 결정

### kube-prometheus-stack 채택
operator + Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + 기본 룰/대시보드 일괄. 컴포넌트 개별 설치 대비 ServiceMonitor/CRD 정합 유지가 쉬움.

### OKE managed control plane — control-plane 스크랩 비활성
`kubeControllerManager` / `kubeScheduler` / `kubeEtcd` / `kubeProxy` `enabled: false`. OKE는 컨트롤 플레인이 관리형이라 해당 메트릭 엔드포인트 접근 불가 → 켜두면 영구 `down` 타겟 + 오탐 알림. 노드/워크로드 메트릭만 수집.

### node-exporter hostNetwork 비활성
PSA `baseline`은 호스트 네임스페이스(hostNetwork)를 금지. `hostNetwork: false`로 baseline 충족. host `/proc`·`/sys` hostPath 마운트는 baseline 허용이라 노드 메트릭 수집 정상 — ServiceMonitor가 pod IP:9100으로 스크랩.

### Grafana 비활성화와 대상 prune
`grafana.enabled: false`는 chart가 Grafana Deployment, Service 등 Grafana 리소스를 더 이상 렌더하지 않게 한다. Grafana는 `persistence.enabled: false`였으므로 별도 PVC나 데이터 마이그레이션은 없다. 그러나 Argo CD `kps` Application은 자동 동기화/자동 prune을 설정하지 않았으므로, Git 변경만으로 기존 워크로드가 삭제되지는 않는다.

배포 시에는 변경된 Git revision과 `kps`의 기존 차이를 확인한 뒤 **검토한 Grafana 리소스만 선택적으로** prune한다. 앱 전체나 `platform-root`를 prune하지 않는다. 아래는 본체·Service·ServiceMonitor만 선택하는 예시다.

```bash
argocd app diff kps --core
argocd app sync kps --prune --core \
  --resource apps:Deployment:grafana \
  --resource :Service:grafana \
  --resource monitoring.coreos.com:ServiceMonitor:grafana
kubectl -n monitoring get deploy,sts,svc -l app.kubernetes.io/name=grafana
```

diff에서 각 대상이 실제로 이번 변경에서 제외된 객체인지 확인한 뒤 실행한다. Grafana 전용 RBAC·대시보드 ConfigMap 등 나머지 제외 객체도 이름별로 검토해 선택적으로 정리한다. 마지막 명령은 본체 제거만 확인하므로 전체 관련 객체 정리와 혼동하지 않는다. 기존 admin Secret은 유지한다. `monitoring-httproute`는 이미 주석만 있는 매니페스트라 public HTTPRoute를 만들지 않는다. Grafana의 emptyDir에 보존할 수동 설정이 있으면 제거 전에 내보내야 하며, 다시 활성화해도 삭제된 UI 데이터가 복원되지는 않는다.

### Grafana 외부 노출 — rollback 시 Gateway 단일 TLS 종료
rollback으로 Grafana를 다시 켤 때 기본 접근은 ClusterIP다. public HTTPRoute를 별도로 활성화하면 `public-gateway`가 `*.ggang.cloud` 와일드카드로 TLS를 종료한다. 현재 선언은 Grafana Service와 HTTPRoute를 렌더하지 않으며, 기존 실행 리소스는 배포 시 별도 정리한다.

### Grafana admin 비밀번호 고정 — rollback용 `existingSecret` (Jenkins 패턴)
`grafana.admin.existingSecret: grafana-admin-fixed`. grafana chart 는 `adminUser`/`adminPassword` 미지정 시 admin 자격을 스스로 `grafana` Secret 에 넣어(고정값 아님) 관리하고, kps 는 ArgoCD 멀티소스로 values 를 git 에서 읽어 매 sync 재렌더한다 → 사용자가 통제하는 고정 자격이 아님. Jenkins `jenkins-admin-fixed` 와 동형으로, 실 자격은 git 밖 `kubectl create secret` 으로 만들고 values 엔 **Secret 이름 포인터만** 둔다. chart 는 `admin.existingSecret` 이 있으면 자체 Secret 을 렌더하지 않고 이 Secret 을 참조하므로, 비번은 공개 레포에 남지 않고 재렌더·재기동과 무관하게 유지.

`adminPassword` 를 values 에 평문/bcrypt 로 박는 방식은 공개 포트폴리오 레포에 자격이 남아 비채택 (argocd 결정과 동일 논리 — `../../argocd/README.md` §4 참조). `userKey`/`passwordKey` 기본값(`admin-user`/`admin-password`)에 맞춰 Secret 키 구성. 향후 OpenBao/ESO 이관 시 대체.

출처: grafana chart `values.yaml` `admin.existingSecret`/`userKey`/`passwordKey` (grafana-community/helm-charts, 조회 2026-07-10 — grafana/helm-charts 는 2026-01-30 이 repo 로 이관).

### 스토리지 — Prometheus 영속 PV (oci-bv 50Gi)
Prometheus는 장기 메트릭 저장소(Thanos) 없는 단독 보관소라 재시작마다 history를 잃지 않도록 `storageSpec.volumeClaimTemplate`로 `oci-bv` 50Gi PVC를 만든다. 현재 다른 `oci-bv` PVC는 NATS JetStream file store가 사용하며, OpenBao는 `emptyDir` 기반 Raft다. retention은 `15d`, retentionSize는 `45GiB`다. Grafana는 비활성 상태이고 Alertmanager는 ephemeral로 유지한다.

Loki는 이 PVC의 별도 `loki/` subPath를 사용하고 Prometheus의 `prometheus-db/`는 유지한다. 두 소비자는 `storage.ggang.cloud/observability=true`인 단일 노드에 배치한다. 이 라벨을 현재 볼륨 연결 노드에 먼저 지정한 뒤 KPS를 동기화해야 한다. fsGroup 2000과 OnRootMismatch를 사용하며 보존 기간·크기는 바꾸지 않는다. 디렉터리 준비와 검증은 [Loki 안내](../loki/README.md)를 따른다.

### 리소스 핀 — Always Free tight
24GB 분배에서 Vault/기존 컴포넌트와 공존하도록 tight. mem limit만 설정(cpu limit 미설정 — throttling 회피).

## 5. 주의 사항

### chart 버전 / CRD
major를 자주 올림 — upgrade 전 CHANGELOG breaking change 확인. CRD는 chart가 설치하지만 `helm uninstall` 시 잔존. major upgrade 시 CRD 수동 apply가 필요할 수 있음.

### Prometheus 디스크 / OOM
`retentionSize 45GiB`는 Prometheus가 compaction에서 목표로 삼는 보존 크기이며 파일시스템 강제 상한은 아니다. compaction 전후 블록 중복과 WAL 때문에 사용량이 일시적으로 이를 넘을 수 있으므로, 50Gi PVC에서 디스크 full을 막는 보장은 아니다. PVC 사용량을 감시하고 압박 시 retention 단축 또는 볼륨 확장을 결정한다. mem 압박은 `resources.limits.memory` 상향 — 메모리는 active series·쿼리 기준이라 디스크 retention과 별개. PVC는 `volumeClaimTemplate`이라 StatefulSet 재생성 뒤에도 유지한다.

출처: Prometheus [Storage 문서](https://prometheus.io/docs/prometheus/latest/storage/)의 compaction 및 retention-size 설명 (2026-10-13 확인).

### Grafana admin 비밀번호 고정 / 회전
Grafana rollback 후에만 admin 자격은 `grafana.admin.existingSecret: grafana-admin-fixed` 로 고정 (§2·§4). 비번 변경 시 이 Secret 을 갱신 후 grafana pod 재기동:

```bash
kubectl -n monitoring create secret generic grafana-admin-fixed \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<new-password>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring rollout restart deploy grafana
```

`existingSecret` 지정 후 chart 는 기존 `grafana` Secret 의 admin 자격을 더 이상 렌더하지 않는다. 현재 비활성화 전환에서는 자격 Secret을 내보내거나 삭제하지 않는다. 자격 평문 base64 는 여전 → OpenBao/ESO 이관 후보.

### metrics-server 별도
HPA(CPU/메모리)·`kubectl top`은 이 스택이 아니라 metrics-server(`metrics.k8s.io`)가 담당 — `../../../infra/metrics-server/`. 보유 여부: `kubectl get deploy -n kube-system metrics-server`.
