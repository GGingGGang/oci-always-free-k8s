# ArgoCD

GitOps 컨트롤 플레인. helm install + HTTPRoute 외부 노출 + self-managed app-of-apps(§6) + 앱 레이어 GitOps 진입점(`app-layer.yaml` → `k8s-gitops`) 까지 구성 완료. SSO 만 별도 turn.

참조:
- https://github.com/argoproj/argo-helm (chart `argo/argo-cd`)
- https://argo-cd.readthedocs.io/en/stable/

## 1. 전제 조건

- `cicd` 네임스페이스 존재 (`../../infra/namespaces/namespaces.yaml`)
- `public-gateway` (istio-system, `*.ggang.cloud` listener) 준비 (`../../infra/istio/gateway.yaml`)
- wildcard TLS Secret `public-wildcard-tls` Ready (`../../infra/cert-manager/`)
- external-dns 동작 (`../../infra/external-dns/`) — HTTPRoute hostname → Cloudflare DNS 자동 sync
- Helm 3.6+
- 권장 버전: argo/argo-cd chart `~7.7.0` (ArgoCD `argocd` Application 은 `7.7.23` 핀). 설치 전 `helm search repo argo/argo-cd --versions` 로 stable 확인

## 2. 설치

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd -n cicd --version "~7.7.0" -f values.yaml --wait

kubectl apply -f httproute.yaml
```

admin 비밀번호 고정 (chart 랜덤 생성 회피 — 클러스터 재구축·pod 재기동과 무관하게 동일 자격증명 유지). `argocd-secret` 의 `admin.password` 는 bcrypt 해시 — chart values 에 해시를 박으면 공개 git 레포에 남으므로, 실 자격증명은 git 밖에 두고 부트스트랩 시 kubectl 로 주입한다 (Jenkins `existingSecret: jenkins-admin-fixed` 와 동일 철학, §4 참조):

```bash
# 1. 원하는 비밀번호의 bcrypt 해시 생성 (argocd CLI)
#    CLI 미설치 시: htpasswd -nbBC 10 "" '<your-password>' | tr -d ':\n' | sed 's/$2y/$2a/'
BCRYPT=$(argocd account bcrypt --password '<your-password>')

# 2. argocd-secret 에 주입 (admin.passwordMtime 갱신 → 기존 발급 JWT 무효화)
kubectl -n cicd patch secret argocd-secret \
  -p "{\"stringData\": {\"admin.password\": \"${BCRYPT}\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"

# 3. chart 가 부팅 시 생성한 랜덤 초기 비번(이제 stale) 제거
kubectl -n cicd delete secret argocd-initial-admin-secret --ignore-not-found
```

`argocd-server` 는 `argocd-secret` 을 informer 로 실시간 감시 → patch 즉시 반영, 재시작 불요. 이후 tailnet 경유 `http://<argocd-server ClusterIP>` (public httproute 재활성 시 `https://argocd.ggang.cloud`) 에서 `admin` / `<your-password>` 로 로그인.

## 3. 검증

```bash
kubectl get pods -n cicd -l app.kubernetes.io/part-of=argocd

# tailnet 경유 접근 (public HTTPRoute 는 주석 처리 — tailnet 전용)
kubectl -n cicd get svc argocd-server          # ClusterIP 확인
curl -I http://<argocd-server ClusterIP>       # tailnet(--accept-routes) 상태에서 응답 확인
```

UI 접근: 브라우저에서 `http://<argocd-server ClusterIP>` (tailnet) → admin login.

> public 도메인 노출이 필요하면 `argocd-httproute` 매니페스트 주석 해제 후 sync — external-dns 가 `argocd.ggang.cloud` A record 를 ~1-5분 내 Cloudflare 에 생성 (`dig +short argocd.ggang.cloud` 확인).

## 4. 결정

### self-managed Application + helm release adopt — 채택

본 레포(인프라)의 `kubernetes/` 매니페스트를 ArgoCD 가 sync 하는 모델 채택. 초기엔 "helm release 만으로 충분" 으로 미채택했으나 결정 뒤집음. 사유:

- git 이 진실 = drift 를 ArgoCD 가 감지(diff). **현재는 adopt 단계라 수동 sync + selfHeal off** — 자동 복구까지 활성화되는 하드닝 turn 은 §6 참조
- 기존 helm release (cert-manager / external-dns / istio / jenkins / argocd 자신) 는 컴포넌트별 Application 으로 adopt
- 앱 레이어는 **별도 AppProject `apps` + 별도 app-of-apps** 로 분리 — config vs source code 분리 + 인프라/앱 권한 경계는 git/project 레벨에서 강제. 본 `platform` 프로젝트(인프라)와 권한·sync 정책 분리.

구조·부트스트랩·adopt 절차는 아래 6장. 앱 레이어 app-of-apps 는 전용 GitOps 레포(`k8s-gitops`)가 보유 (project `apps`, auto-sync 활성 — 인프라와 달리 디스럽션 비용 낮음).

### 외부 노출 — Gateway TLS 단일 종료

`public-gateway` 의 `https-wildcard` listener 가 `*.ggang.cloud` 와일드카드 인증서로 TLS 종료. ArgoCD `argocd-server` 는 `--insecure` 유지하고 cluster 내부에서는 HTTP(:80) 로 listen. mesh 내부 트래픽은 Istio Ambient(ztunnel) 가 L4 mTLS 로 보호.

이중 TLS 종료(Gateway + ArgoCD self-TLS) 미채택 사유:
- ArgoCD gRPC + gRPC-Web 이 single port 에서 동작 — 중간단 재암호화 시 ALPN/HTTP2 협상 골치
- ambient mesh 가 이미 L4 mTLS 보장 → 평문 hop 없음
- argoproj 공식 ingress 가이드도 *TLS termination at ingress* 패턴이 default

SSO 도입 turn 에서 `dex.enabled: true` + GitHub OAuth 활성, `admin` user 비활성.

### dex / notifications / redis-ha 비활성

- `dex.enabled: false` — SSO turn 전까지 불필요
- `notifications.enabled: false` — Slack/email 연동 turn 에 활성
- `redis-ha.enabled: false` — single Redis. controller HA 불필요 (Always Free 24GB RAM 우선)

### admin 비밀번호 고정 — values(git) 대신 imperative patch

Jenkins 는 `existingSecret: jenkins-admin-fixed` 로 실 자격증명을 git 밖에 두고 참조한다. ArgoCD 는 admin 비번을 임의 Secret 으로 지정하는 지시자가 없고 반드시 `argocd-secret` 의 `admin.password`(bcrypt) 에 살아야 한다. 고정 방법은 둘:

- **(A) `configs.secret.argocdServerAdminPassword` + `...Mtime` 를 values 에 박기** — 선언적이나 bcrypt 해시가 공개 레포에 남는다. mtime 미고정 시 chart 가 `now()` 로 렌더해 매 sync 마다 churn.
- **(B) 부트스트랩 때 `argocd-secret` 을 kubectl patch** (§2 채택) — 실 자격증명 git 밖. Jenkins 패턴과 동형.

**(B) 채택.** 공개 포트폴리오 레포라 해시라도 offline brute-force 표면을 남기지 않음 + Jenkins 선례와 일관. self-manage sync 가 patch 필드를 덮지 않는 근거: chart `argocd-secret.yaml`(7.7.23) 은 `argocdServerAdminPassword` 가 빈 값이면 `admin.password` 키를 렌더하지 않고, Secret 에 `helm.sh/hook`/`resource-policy` 어노테이션이 없으며, `argocd.yaml` 이 `ServerSideApply=true` + prune/automated 미설정(adopt 단계)이라 렌더 대상이 아닌 필드는 유지된다. 향후 Vault Agent Injector / ESO 로 이관 시 (A)/(B) 모두 대체.

### 리소스 핀

총 ~1312Mi (controller 1024 + repo 128 + server 64 + appset 64 + redis 32). Always Free 분배 (Vault + Prometheus 우선) 에 맞춰 tight 설정. repo-server limit 은 512Mi — 대형 차트(kyverno 등) 렌더 피크에서 256Mi limit 로는 OOMKill(`ComparisonError ... EOF`) 발생. limit 만 상향, requests 불변이라 스케줄링 장부 영향 없음.

controller가 옛 768Mi request / 1Gi limit 근처(실사용 990~1003Mi)에서 GC 압박으로 `readinessProbe`(`/healthz`, `timeoutSeconds: 1`) 간헐 실패(11h+ 지속) → request/limit을 1Gi/1.5Gi로 상향. 파드가 뜬 노드 기준 requests/limits 여유 충분해 상향 부담 없음.

## 5. 주의 사항

### chart 버전 확인

`~7.7.0` 은 작성 시점 추론. 설치 전:

```bash
helm search repo argo/argo-cd --versions | head -5
```

CHANGELOG 에서 breaking change 확인 (특히 6.x → 7.x, 7.x → 8.x).

### admin 비밀번호 고정 / 회전

chart 가 부팅 시 만드는 `argocd-initial-admin-secret` 은 plain text 랜덤값 — 클러스터 재구축마다 바뀐다. §2 절차로 `argocd-secret` 의 `admin.password`(bcrypt) 를 알려진 고정값으로 patch 하면 재구축·재기동과 무관하게 동일 비번 유지. 비번을 바꿀 땐 같은 patch 를 새 해시로 재실행하면 되고, `admin.passwordMtime` 갱신으로 기존 발급 JWT 가 무효화된다. SSO 도입 turn 에 `admin` 사용자 비활성화 + role 기반 접근으로 전환.

### reconciliation 주기

`timeout.reconciliation: 180s` — 기본 180s 명시. webhook 적용 시 즉시 반영 — webhook 은 SSO turn 이후.

### CLI 접근

public Gateway/HTTPRoute 가 주석 처리된 현재, CLI 는 **core 모드**가 1순위 — `argocd-server` 를 거치지 않고 kubeconfig 로 kube API 의 Application CR 을 직접 조작한다 (외부 노출·비밀번호 로그인 불요):

```bash
argocd app list --core          # ARGOCD_OPTS=--core 로 고정 가능
```

core 모드는 argocd 설치 NS 를 kube context 의 현재 namespace 로 인식하므로 context 가 `cicd` 여야 한다.

public 도메인 재활성(httproute 주석 해제) 시엔 gRPC 경유 로그인도 가능 — `argocd` CLI 는 gRPC 라 `--grpc-web` 필요(없으면 HTTP/2 protocol error):

```bash
argocd login argocd.ggang.cloud --grpc-web
```

## 6. self-managed GitOps (app-of-apps)

기존 helm release 를 부수지 않고 ArgoCD 관리로 흡수(adopt)하는 구조. `cicd` 네임스페이스(ArgoCD 거주지)에서 동작.

```
argocd/
├── project.yaml        AppProject "platform" — sourceRepo/destination/리소스 화이트리스트
├── root.yaml           Application "platform-root" — apps/ 디렉터리를 가리키는 app-of-apps
└── apps/               root 가 관리하는 자식 Application 들
    ├── namespaces.yaml          (raw)
    ├── cert-manager.yaml        (helm) + cert-manager-resources.yaml (raw: ClusterIssuer/Certificate)
    ├── external-dns.yaml        (helm)
    ├── metrics-server.yaml      (helm)
    ├── istio-base/istiod/istio-cni/ztunnel.yaml  (helm ×4) + istio-gateway.yaml (raw: Gateway/redirect)
    ├── kps.yaml                 (helm) + monitoring-httproute.yaml (raw)
    ├── jenkins.yaml             (helm) + jenkins-rbac.yaml / jenkins-httproute.yaml (raw)
    ├── argocd.yaml              (helm, self-manage) + argocd-httproute.yaml (raw)
    ├── redis.yaml               (raw)
    ├── kyverno.yaml             (helm) + kyverno-policies.yaml (raw: ClusterPolicy)
    └── app-layer.yaml           앱 레이어 진입 포인터 → k8s-gitops/argocd
```

### 인프라 → 앱 레이어 체인

`app-layer.yaml` 은 `platform-root` 가 관리하는 자식 Application(`app-layer-root`) 로, 앱 레이어 GitOps 레포([`k8s-gitops`](https://github.com/GGingGGang/k8s-gitops))의 `argocd/` 에서 `project.yaml`(AppProject `apps`) + `root.yaml`(app-of-apps `apps-root`) 만 sync 한다. 이후 `apps-root` 가 `k8s-gitops/argocd/apps/` 의 서비스 Application 을 관리 — 앱 매니페스트 정의는 전부 `k8s-gitops` 소유, 본 레포엔 진입 포인터 1개만. 현재 `core.yaml`/`batch.yaml`/`auth.yaml` 존재 (`core`/`batch` 는 CI/CD e2e 배포 검증됨).

```
platform-root (본 레포, 인프라)
 └── app-layer-root ──► k8s-gitops/argocd  (project.yaml + root.yaml)
        └── apps-root ──► k8s-gitops/argocd/apps  ──► core / batch / auth
```

포인터 자신(`app-layer-root`)은 `apps` AppProject 를 *정의*하는 `project.yaml` 을 배포하므로 `apps` 프로젝트에 속할 수 없다(순환) → `project: platform`. 그래서 `project.yaml` 의 `sourceRepos` 에 `k8s-gitops.git` 을 추가해 두었다.

### 핵심 원칙

- **Application 이름 = 원래 `helm install <name>`**. ArgoCD 가 Application 이름을 helm release 명으로 렌더하므로, 이름이 어긋나면 adopt 가 아니라 리소스 *중복 생성* 이 됨. (`kps`/`istiod`/`istio-cni` 등 전부 원래 release 명 유지)
- **helm chart + git values = multi-source**. helm repo 를 chart source 로, 본 레포를 `ref: values` 로 두고 `$values/...` 로 values 파일 참조. values 의 단일 진실은 각 컴포넌트 폴더의 `values.yaml` 유지.
- **adopt 단계 sync policy = 수동 + prune off**. `syncPolicy.automated` 미설정. 돌던 리소스를 추적만 하고 ArgoCD 는 구경꾼. `selfHeal`/`prune`/`automated` 활성은 하드닝 turn 에서.
- **`ServerSideApply=true`**. 기존 client-side last-applied annotation 과 충돌 없이 field ownership 흡수.

### 부트스트랩

```bash
# AppProject + root 1회 적용 (root 가 이후 apps/ 를 관리)
kubectl apply -f project.yaml
kubectl apply -f root.yaml

# root sync → apps/ 자식 Application 생성 (수동)
argocd app sync platform-root

# 자식들이 OutOfSync 로 뜸 — sync-wave 순서로 하나씩 diff 검수 후 sync
argocd app diff cert-manager     # diff 가 instance 라벨/tracking annotation 추가 수준이면 정상 adopt
argocd app sync cert-manager
```

adopt 정상 판정: diff 가 `app.kubernetes.io/instance` 라벨 + `argocd.argoproj.io/tracking-id` annotation 추가 수준(거의 0)이면 OK. spec 자체 diff 가 크면 chart 버전/values 불일치 의심.

### sync-wave 순서 (cold-rebuild 시 의존 순서)

| wave | Application |
|------|-------------|
| 0 | namespaces |
| 1 | cert-manager, istio-base |
| 2 | external-dns, metrics-server, istiod, istio-cni, ztunnel |
| 3 | cert-manager-resources, kps, jenkins-rbac |
| 4 | istio-gateway, jenkins, argocd (self) |
| 5 | jenkins-httproute, argocd-httproute, monitoring-httproute, app-layer-root |
| 6 | redis, kyverno |
| 7 | kyverno-policies (ClusterPolicy — kyverno CRD 선행) |

`argocd` 자기 관리(self-manage)는 잘못 sync 하면 자기 손을 자르므로 wave 4 + **수동 sync 전용**. 하드닝 turn 에서도 selfHeal 활성은 마지막.

### chart 버전 핀 — 실측 exact

자식 helm Application 의 `targetRevision` 은 `helm list -A` 실측값으로 exact pin — 첫 diff 가 업그레이드가 아니라 adopt(거의 0)로 떨어지게.

| release | chart 버전 |
|---------|-----------|
| cert-manager | `v1.18.6` |
| external-dns | `1.16.1` |
| metrics-server | `3.13.1` |
| istio base/istiod/cni/ztunnel | `1.29.3` |
| kps | `75.0.0` |
| jenkins | `5.9.26` |
| argocd | `7.7.23` |
| kyverno | `3.8.2` |

upgrade 시엔 helm 으로 먼저 올린 뒤(`helm upgrade`) `helm list -A` 로 실측값을 다시 박거나, range 로 풀고 자동 추종. 범위 핀은 새 patch 가 나오면 OutOfSync 노이즈가 생기므로 adopt 단계에선 exact 유지.

### adopt 제외 3건

- **gateway-api CRD** — 원격 release 아티팩트(`standard-install.yaml`)라 git tree 의 directory source 로 못 가리킴. 클러스터 부트스트랩(`kubectl apply --server-side`)으로 관리. CRD 는 클러스터 수명주기와 함께 가는 토대라 GitOps 제외가 합리적. (`../../infra/gateway-api/`)
- **openbao** — KMS OCID 를 `sed` 로 주입한 `values.local.yaml` 이 git-ignore(`*.local.*`). git-sourced values 로는 placeholder 만 읽혀 깨짐. adopt 하려면 (a) OCID 를 git 에 박거나(식별자라 비밀 아님 — 보안은 instance-principal Policy 담당) (b) ArgoCD Vault Plugin / `helm.parameters` 주입. 결정 보류 → helm 운영 유지. (`../openbao/`)
- **tailscale** — 관리 플레인 *접근 계층*. ArgoCD/클러스터 장애 시 *들어가는* 경로라 ArgoCD 건강에 의존하면 자기모순(prune 한 번에 접근 경로 증발). gateway-api CRD 와 같은 부트스트랩 등급으로 `kubectl apply` 관리, auth Secret 은 git 밖. (`../../infra/tailscale/`)
