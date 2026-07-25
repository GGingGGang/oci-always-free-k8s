# Monitoring (kube-prometheus-stack)

메트릭/알림/대시보드. Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + prometheus-operator 일괄. Alertmanager 는 Discord 웹훅으로 배선됨 (AlertmanagerConfig CR — 절차·구조는 §2).

참조:
- https://github.com/prometheus-community/helm-charts (chart `prometheus-community/kube-prometheus-stack`)
- https://kubernetes.io/docs/concepts/security/pod-security-standards/ (PSA baseline)

## 1. 전제 조건

- `monitoring` 네임스페이스 + PSA `enforce=baseline` (`../../infra/namespaces/`)
- `grafana-admin-fixed` Secret 선존재 (`monitoring` NS) — Grafana admin 고정 자격. `values.yaml` `grafana.admin.existingSecret` 이 참조하므로 미존재 시 Grafana pod 가 `secretKeyRef` 로 기동 실패 (§2)
- Grafana 외부 노출용: `public-gateway` `https-wildcard` listener + wildcard TLS Secret `public-wildcard-tls` Ready (`../../infra/istio/`, `../../infra/cert-manager/`)
- external-dns 동작 — HTTPRoute hostname → Cloudflare DNS (`../../infra/external-dns/`)
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

# Grafana admin 자격 고정 (chart 기본 자동 관리 회피 — helm/sync 재렌더와 무관하게 동일 자격 유지,
# Jenkins jenkins-admin-fixed 와 동일 패턴). values.yaml grafana.admin.existingSecret 가 이걸 참조
kubectl create secret generic grafana-admin-fixed \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<your-password>' \
  -n monitoring

helm install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --version "~75.0.0" -f values.yaml --wait

kubectl apply -f httproute.yaml
```

admin 자격은 `grafana.admin.existingSecret: grafana-admin-fixed` 로 고정 (`values.yaml`). chart 는 `admin.existingSecret` 이 지정되면 자체 admin Secret 을 만들지 않고 이 Secret 을 `GF_SECURITY_ADMIN_USER/PASSWORD` 로 주입 → pod 재기동·helm upgrade·ArgoCD sync 와 무관하게 동일 자격 유지 (chart 미지정 시엔 chart 가 `grafana` Secret 을 스스로 관리 = 사용자 고정값 아님):

```bash
kubectl -n monitoring get secret grafana-admin-fixed \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo
# tailnet 경유 http://<grafana ClusterIP> → admin / <위 출력>  (public httproute 는 주석 처리)
```

### 알림 수신처 배선 (Discord)

Alertmanager 는 배선 전까지 수신처가 `"null"` 뿐 — 알림이 어디로도 발송되지 않는다. 라우팅/수신처는 **`alertmanager-config.yaml`(AlertmanagerConfig CR, git-가시)** 이 소유하고 `values.yaml` 의 `alertmanagerSpec.alertmanagerConfiguration` 이 참조한다(global 모드). 웹훅 URL 만 사전 수동 Secret 으로 분리 (`grafana-admin-fixed` 와 동일 패턴) — CR 의 `apiURL` 이 secretKeyRef 로 가리키고, operator 가 config 생성 시점에 값을 인라인하므로 파드 마운트 불요.

> chart `alertmanager.config` + `webhook_url_file` 방식은 불가 — AM 바이너리(v0.28)는 지원하지만 **prometheus-operator(v0.83) config 파서가 그 필드를 몰라** `-generated` Secret 생성을 거부한다. AlertmanagerConfig 는 operator 자기 CRD 라 이 파서 불일치가 구조적으로 없다. helm CLI 직접 upgrade 도 불가 — kps 는 ArgoCD 가 ServerSideApply 로 소유해 field manager 충돌로 거부된다 (`../argocd/README.md` §6 adopt 구조).

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

kubectl -n monitoring get svc grafana          # ClusterIP 확인 (tailnet 경유 접근)
# public HTTPRoute 재활성(주석 해제) 시: get httproute grafana 의 Accepted=True + dig +short grafana.ggang.cloud
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

### Grafana 외부 노출 — Gateway 단일 TLS 종료
argocd 패턴 동일. Grafana는 ClusterIP HTTP, `public-gateway`가 `*.ggang.cloud` 와일드카드로 TLS 종료. mesh 내부는 Istio Ambient L4 mTLS.

### Grafana admin 비밀번호 고정 — `existingSecret` (Jenkins 패턴)
`grafana.admin.existingSecret: grafana-admin-fixed`. grafana chart 는 `adminUser`/`adminPassword` 미지정 시 admin 자격을 스스로 `grafana` Secret 에 넣어(고정값 아님) 관리하고, kps 는 ArgoCD 멀티소스로 values 를 git 에서 읽어 매 sync 재렌더한다 → 사용자가 통제하는 고정 자격이 아님. Jenkins `jenkins-admin-fixed` 와 동형으로, 실 자격은 git 밖 `kubectl create secret` 으로 만들고 values 엔 **Secret 이름 포인터만** 둔다. chart 는 `admin.existingSecret` 이 있으면 자체 Secret 을 렌더하지 않고 이 Secret 을 참조하므로, 비번은 공개 레포에 남지 않고 재렌더·재기동과 무관하게 유지.

`adminPassword` 를 values 에 평문/bcrypt 로 박는 방식은 공개 포트폴리오 레포에 자격이 남아 비채택 (argocd 결정과 동일 논리 — `../argocd/README.md` §4 참조). `userKey`/`passwordKey` 기본값(`admin-user`/`admin-password`)에 맞춰 Secret 키 구성. 향후 OpenBao/ESO 이관 시 대체.

출처: grafana chart `values.yaml` `admin.existingSecret`/`userKey`/`passwordKey` (grafana-community/helm-charts, 조회 2026-07-10 — grafana/helm-charts 는 2026-01-30 이 repo 로 이관).

### 스토리지 — Prometheus 영속 PV (oci-bv 50Gi)
Prometheus 는 장기 메트릭 저장소(Thanos) 없는 단독 보관소 → 재시작마다 history 소실은 비용 과다. Always Free Block Volume 한도(부트 ×2 + PV ×2 = 4볼륨 / 총 200GB)의 PV 2칸 우선순위 = **Vault, Prometheus**. `storageSpec.volumeClaimTemplate` 로 `oci-bv` 50Gi 동적 프로비저닝, retention `15d` / retentionSize `45GiB`(디스크 full 전 prune 가드). Grafana/Alertmanager 는 ephemeral 유지(대시보드=코드, 알림 상태는 짧은 보존이라 손실 허용). Loki(오브젝트 스토리지) / Tempo(emptyDir) 후속과 정합.

### 리소스 핀 — Always Free tight
24GB 분배에서 Vault/기존 컴포넌트와 공존하도록 tight. mem limit만 설정(cpu limit 미설정 — throttling 회피).

## 5. 주의 사항

### chart 버전 / CRD
major를 자주 올림 — upgrade 전 CHANGELOG breaking change 확인. CRD는 chart가 설치하지만 `helm uninstall` 시 잔존. major upgrade 시 CRD 수동 apply가 필요할 수 있음.

### Prometheus 디스크 / OOM
`retentionSize 45GiB` < PV `50Gi` — 디스크 full 전에 prune. 시계열 급증으로 디스크 압박 시 retention 단축. mem 압박은 `resources.limits.memory` 상향 — 메모리는 active series·쿼리 기준이라 디스크 retention 과 별개. PVC 는 `volumeClaimTemplate` 이라 STS 재생성 시에도 유지(블록볼륨 한도 = 부트 2 + PV 2 고정).

### Grafana admin 비밀번호 고정 / 회전
admin 자격은 `grafana.admin.existingSecret: grafana-admin-fixed` 로 고정 (§2·§4). 비번 변경 시 이 Secret 을 갱신 후 grafana pod 재기동:

```bash
kubectl -n monitoring create secret generic grafana-admin-fixed \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<new-password>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring rollout restart deploy grafana
```

`existingSecret` 지정 후 chart 는 기존 `grafana` Secret 의 admin 자격을 더 이상 렌더하지 않는다 — 컷오버 후 남는 구 `grafana` Secret 은 미사용(무해, 정리 원하면 삭제 가능). 자격 평문 base64 는 여전 → OpenBao/ESO 이관 후보.

### metrics-server 별도
HPA(CPU/메모리)·`kubectl top`은 이 스택이 아니라 metrics-server(`metrics.k8s.io`)가 담당 — `../../infra/metrics-server/`. 보유 여부: `kubectl get deploy -n kube-system metrics-server`.
