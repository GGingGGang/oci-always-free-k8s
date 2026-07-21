# Jenkins (JCasC + emptyDir)

선언적 Jenkins. 모든 설정은 JCasC(Configuration as Code)로 git 추적, controller는 emptyDir 운영.

참조:
- https://github.com/jenkinsci/configuration-as-code-plugin
- https://artifacthub.io/packages/helm/jenkinsci/jenkins
- https://github.com/jenkinsci/kubernetes-plugin

## 1. 전제 조건

- `cicd` + `build` 네임스페이스 존재 (`../../infra/namespaces/namespaces.yaml`)
  - `cicd` — Jenkins controller (PSA `baseline`)
  - `build` — Kaniko 빌드 Pod 격리 (PSA `privileged`)
- Gateway API CRD + Istio Gateway `public-gateway` 동작 (`../../infra/istio/`)
- cert-manager + wildcard Certificate Ready=True (`../../infra/cert-manager/`)
- external-dns 동작 (`../../infra/external-dns/`)
- Helm 3.6+
- 권장 버전: jenkins/jenkins chart `~5.9.0` (ArgoCD `jenkins` Application 은 `5.9.26` 핀)

## 2. 설치

```bash
export GHCR_USER=<your-github-user>
export GHCR_TOKEN=<your-ghcr-write-token>

kubectl apply -f rbac.yaml

kubectl create secret docker-registry ghcr-push \
  --docker-server=ghcr.io \
  --docker-username="${GHCR_USER}" \
  --docker-password="${GHCR_TOKEN}" \
  -n build

# admin 자격증명 고정 (chart 랜덤 생성 회피 — helm upgrade/sync 마다 비번 변경 방지)
kubectl create secret generic jenkins-admin-fixed \
  --from-literal=jenkins-admin-user=admin \
  --from-literal=jenkins-admin-password='<your-password>' \
  -n cicd

# 매니페스트 bump 용 git PAT — JCasC github-token credential 의 실값 (containerEnv GIT_PAT 로 주입)
# 미존재 시 controller pod 가 secretKeyRef 로 기동 실패
kubectl create secret generic jenkins-git-pat \
  --from-literal=token='<github-pat-repo-scope>' \
  -n cicd

helm repo add jenkins https://charts.jenkins.io
helm repo update

helm install jenkins jenkins/jenkins -n cicd --version "~5.9.0" -f values.yaml --wait

kubectl apply -f httproute.yaml
```

`httproute.yaml` 한 파일에 webhook 라우트(active, `/github-webhook/` 한 경로 public)와 admin UI 라우트(parked, 주석 — tailnet 컷오버)를 `---` 로 함께 담는다. ArgoCD `jenkins-httproute` Application(`directory.include: httproute.yaml`)이 이 파일을 sync — 위 `kubectl apply` 는 부트스트랩이고 이후 GitOps 가 adopt. admin 접근은 tailnet ClusterIP (결정 §HTTPRoute 참조).

`ghcr-push` Secret 은 `build` NS 에 존재해야 함 (Kaniko podTemplate 이 마운트). GHCR token scope: `write:packages` + `read:packages`. 향후 Vault Agent Injector 또는 GitHub App Installation Token 으로 이관 예정.

admin 계정은 `existingSecret: jenkins-admin-fixed` 로 고정 (`controller.admin` value). chart 가 매 install/upgrade 마다 랜덤 비번을 재생성하던 문제를 제거 — pod 재기동·helm upgrade 와 무관하게 동일 자격증명 유지:

```bash
kubectl get secret jenkins-admin-fixed -n cicd -o jsonpath='{.data.jenkins-admin-user}'     | base64 -d ; echo
kubectl get secret jenkins-admin-fixed -n cicd -o jsonpath='{.data.jenkins-admin-password}' | base64 -d ; echo
```

## 3. 검증

```bash
kubectl get pods -n cicd
kubectl get svc,httproute -n cicd
kubectl logs -n cicd jenkins-0 -c jenkins --tail=50 | grep -i "casc\|configuration-as-code"
```

JCasC 적용 확인:

```bash
kubectl exec -n cicd jenkins-0 -c jenkins -- ls /var/jenkins_home/casc_configs/
```

브라우저 (tailnet 경유 ClusterIP — public httproute 는 주석 처리):
- `http://<jenkins ClusterIP>:8080` 접근 → 로그인 → JCasC seed에 박힌 system message 확인
- Manage Jenkins → Configuration as Code → "Reload existing configuration" 동작 확인

webhook 라우트 (public, path-scoped):

```bash
kubectl describe httproute jenkins-webhook -n cicd | grep -A5 "Parents"   # Accepted=True, ResolvedRefs=True

# webhook 경로만 통과 — GitHub plugin 엔드포인트는 GET 405/200, POST 가 실제 트리거
curl -sI "https://ci-hook.ggang.cloud/github-webhook/"
# admin UI 경로는 라우트 매칭 없어 404 (노출 안 됨 확인)
curl -sI "https://ci-hook.ggang.cloud/"
```

**선언성 검증 — pod 재시작 후 동일 상태**:

```bash
kubectl delete pod jenkins-0 -n cicd
kubectl wait --for=condition=ready pod/jenkins-0 -n cicd --timeout=180s
# 브라우저 재접속 → 동일 system message + admin 사용자 유지 확인 (emptyDir이라도 JCasC가 재구성)
```

DNS 자동 등록은 public HTTPRoute 재활성(주석 해제) 시에만 — external-dns + Cloudflare:

```bash
nslookup "jenkins.ggang.cloud" 1.1.1.1
curl -vIk "https://jenkins.ggang.cloud"
```

Kaniko podTemplate 적용 확인:

```bash
kubectl exec -n cicd jenkins-0 -c jenkins -- \
  cat /var/jenkins_home/casc_configs/*.yaml | grep -A2 "label: kaniko"

kubectl get secret ghcr-push -n build -o jsonpath='{.type}'
# kubernetes.io/dockerconfigjson 출력되어야 함

kubectl get secret cosign-key ghcr-pull -n build
# cosign-key: 서명 개인키+비번 / ghcr-pull: private cosign 이미지 pull (podTemplate imagePullSecrets)

kubectl get sa kaniko-builder -n build
```

Jenkins UI → Manage Jenkins → Clouds → kubernetes → Pod Templates → `kaniko` 항목 존재 확인.

## 4. 결정

### emptyDir + JCasC

PV(`oci-bv` 50Gi) 대신 emptyDir. 사유:

- **분배 정합** — Always Free Block Volume 4볼륨 한도 (boot 2 + PV 2). PV 슬롯은 Vault + Prometheus 우선
- **GitOps 단일 진실** — 모든 설정이 `values.yaml` JCasC seed에 박힘. UI 클릭으로 영구 변경 ❌ (UI 변경은 next reload에서 git값으로 덮임)
- **DR narrative** — pod 날아가도 git이 source of truth. PV 복원 불필요
- **trade-off**: 빌드 history 손실 (재시작마다). 다만 빌드 메타데이터는 git + GHCR + Loki(observability 도입 시)에 영구 보존

### 단일 인스턴스 controller

HA controller는 Jenkins 라이선스/플러그인 호환성 폭증. 본 환경은 Always Free 24GB RAM에서 *동작/재현성*이 *고가용성*보다 우위. RTO는 "JCasC 재로드 + agent pod 재생성"으로 분단위.

### Plugins 전체 pin + `installLatestPlugins: false`

모든 plugin 을 `<name>:<version>` 형식 명시 pin. *재현성 우선* — 같은 values.yaml 로 어디서 install 해도 같은 plugin set. `timestamper` 포함 (Jenkinsfile `options { timestamps() }` 가 요구 — 미설치 시 `Invalid option type "timestamps"` 로 파이프라인 컴파일 실패).

핵심 plugin 그룹:

- **Pipeline 코어**: `workflow-*` 12종 + `pipeline-*` 9종 + `pipeline-model-*` 4종 (Declarative Pipeline 포함)
- **Kubernetes plugin**: `kubernetes` + `kubernetes-client-api` + `kubernetes-credentials` (동적 agent)
- **JCasC**: `configuration-as-code` + `snakeyaml-api`
- **GitHub/Git 연동**: `git`, `git-client`, `github`, `github-api`, `github-branch-source`, `credentials-binding`
- **UI**: `pipeline-stage-view`, `pipeline-rest-api`
- **Transitive deps**: API plugin 다수 (`commons-*`, `jackson2-api`, `okhttp-api` 등) — *명시 pin 안 하면 UC-latest 로 떠서 mismatch 발생 위험*

명시 일부 pin 만으로는 transitive 통제 불가. `pipeline-model-api/extensions/definition` trio 처럼 release wave 가 어긋나면 Declarative Pipeline 로드 실패. *전체 plugin set 을 한 번에 pin* 하는 것이 유일한 재현성 보장.

#### Plugin upgrade 절차

CVE 발생 또는 chart bump 시:

1. 안전 환경에서 `installLatestPlugins: true` + 임시 install → 동작 검증
2. plugin manager 또는 script console 로 실 설치 version 캡처:
   ```bash
   kubectl exec -n cicd jenkins-0 -c jenkins -- \
     ls /var/jenkins_home/plugins | awk -F'.jpi' '{print $1}' | sort -u
   ```
   또는 script console (`http://<jenkins ClusterIP>:8080/script`, tailnet) 에서:
   ```groovy
   Jenkins.instance.pluginManager.plugins.each { println "${it.shortName}:${it.version}" }
   ```
3. 출력을 values.yaml `installPlugins` 로 박음 (정렬 권장)
4. `installLatestPlugins: false` 유지
5. helm upgrade + rollout restart → 재현성 회복

plugin 단독 upgrade ❌ — JCasC + chart + plugin 조합 호환성 검증된 묶음 유지.

### Agent — Kubernetes plugin + `containerCap: 2`

빌드 agent는 동적 Pod (`agent.enabled: true`). 동시 빌드 2개로 제한 (24GB RAM 환경 보호). 빌드 종료 시 Pod 자동 삭제 — stateless.

agent image 태그 핀 (`3327.v868139a_d00e0-3-jdk21`) — floating 회피. **`-alpine` variant 비채택**: alpine 태그는 amd64 단일 아키라 A1.Flex(ARM64) 노드에서 `no image found ... architecture "arm64"` 로 pod 기동 실패. `-jdk21`(Debian 기반)은 멀티아치 매니페스트(arm64 포함). registry 매니페스트로 아키 검증:

```bash
token=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:jenkins/inbound-agent:pull" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
curl -s -H "Authorization: Bearer $token" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://registry-1.docker.io/v2/jenkins/inbound-agent/manifests/<tag>" \
  | python3 -c "import sys,json;[print(m['platform']) for m in json.load(sys.stdin).get('manifests',[])]"
```

이미지 경로엔 `docker.io/` prefix 명시 (`agent.image.repository` + kaniko podTemplate jnlp). CRI-O 는 short-name 을 거부(`short name ... ambiguous`).

### Kaniko podTemplate — `agent.podTemplates.kaniko`

JCasC 로 선언적 정의. Jenkinsfile 에서 `agent { label 'kaniko' }` 만 쓰면 됨.

핵심 결정:

- **`build` NS 격리** — Kaniko 가 root + capabilities 요구. `cicd` 의 PSA `baseline` 을 우회하지 않고 `build` NS (`enforce: privileged`) 로 분리. controller 침해 시 빌드 SA 직접 도달 ❌
- **`kaniko-builder` SA + `automountServiceAccountToken: false`** — Kaniko 는 GHCR push 외 k8s API 호출 불필요. SA 토큰 마운트 차단으로 *빌드 컨테이너가 k8s API 통한 측면 이동 ❌*
- **`:v1.23.2-debug` 이미지** — Jenkins Kubernetes plugin 이 컨테이너에 `sleep` 주입해서 agent 가 살아 있어야 `exec` 가능. `:debug` 는 busybox 포함, default `:latest` 는 executor binary 만 있어 sleep ❌
- **`ghcr-push` Secret projected 마운트** — `/kaniko/.docker/config.json` 으로 kaniko 가 자동 인식. Secret type `kubernetes.io/dockerconfigjson` 필수
- **ARM64 빌드** — A1.Flex 워커. Kaniko 는 호스트 아키텍처 따라감 → ARM 자동. Jenkinsfile 에서 `--customPlatform=linux/arm64` 명시 권장 (base image multi-arch 검증 의무)

cache + memory 폭주 회피 args (Jenkinsfile 에서 주입):

```bash
--cache=true
--cache-repo=ghcr.io/${GHCR_USER}/cache
--cache-ttl=168h
--snapshot-mode=redo
--use-new-run
--ignore-path=/busybox       # durable-task hang 회피 (아래)
--ignore-path=/home/jenkins
```

**`--ignore-path` 필수 — kaniko ↔ durable-task hang**: kaniko 는 최종 이미지 fs 를 컨테이너 `/` 에 풀며 debug 이미지의 shell(`/busybox`)을 덮어쓴다. 그러면 Jenkins durable-task wrapper 가 step 종료코드(`jenkins-result.txt`)를 못 써서 — **이미지는 GHCR push 성공인데 잡은 무한 hang**. `/busybox`(shell)와 `/home/jenkins`(agent workspace) 를 ignore-path 로 보존하면 해소. 증상 식별: 살아있는 `jnlp` 컨테이너로 `find /home/jenkins/agent/workspace -name jenkins-result.txt` → 파일 부재면 이 케이스.

위 `/kaniko/executor` 옵션들은 shared library `kanikoBuild` step 이 내부적으로 조립한다 (`jenkins-shared-library/vars/kanikoBuild.groovy`). 앱 레포 `Jenkinsfile` 은 raw kaniko 호출도, 개별 스테이지 나열도 하지 않고 `ci()` 메타 step 하나로 전체 파이프라인(Build & Push → Image Scan → Sign → Bump)을 조립한다:

```groovy
@Library('shared') _

ci(service: 'core')
```

서비스별로 갈리는 값(스캔 게이트, 서명 여부)은 Jenkinsfile 이 아니라 shared library 의 `resources/ci/services.yaml` 한 파일에 모여 있다 — 새 서비스 추가·설정 변경이 그 파일 한 줄로 끝나고 `ci.groovy`/Jenkinsfile 은 무수정. `services.yaml` 파싱에 `installPlugins` 의 `pipeline-utility-steps`(`readYaml` 스텝) 필요.

`ci()`/`kanikoBuild`/`deployBump` 상세 파라미터는 [`jenkins-shared-library`](https://github.com/GGingGGang/jenkins-shared-library) 레포의 README 참조.

### Trivy 컨테이너 + HTML 리포트 게시 — `agent.podTemplates.kaniko` 확장

같은 pod 에 `trivy`(`docker.io/aquasec/trivy:0.72.0`, kaniko 와 동일하게 `sleep 99d` 로 유지) 컨테이너 추가. kaniko 와 같은 `ghcr-push` docker config 를 `/trivy/.docker` 로 projected 마운트(`DOCKER_CONFIG` env) — push 된 이미지를 GHCR 에서 pull 해 스캔하므로 registry 인증 필요. 취약점 DB 는 인터넷 아웃바운드로 스캔 시점에 갱신(별도 volume 불요).

- **`installPlugins`에 `htmlpublisher` 포함** — `publishHTML` 스텝 제공.
- **`controller.javaOpts` 로 CSP 완화**: Jenkins 기본 `hudson.model.DirectoryBrowserSupport.CSP`(`default-src 'none'`)는 아카이브/HTML Publisher 가 서빙하는 정적 페이지에서 인라인 `<style>`/`<script>` 를 전부 막는다. trivy 공식 HTML 템플릿(`jenkins-shared-library/resources/trivy/html.tpl`)이 인라인 스타일 + 인라인 스크립트(정렬/토글용, 외부 CDN 참조 없음 — 체크인 전 직접 확인)만 쓰므로, 전면 비활성화 대신 `default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self'` 로 좁혀서 완화.
- 스캔/HTML 변환/게시 로직은 shared library `trivyImageScan` step 이 내부적으로 조립 (`jenkins-shared-library/vars/trivyImageScan.groovy`, 파라미터는 `jenkins-shared-library/README.md` 참조). `ci()` 가 Image Scan 스테이지로 자동 호출 — 앱 레포 Jenkinsfile 이 직접 부르지 않는다. 게이트 on/off 는 `services.yaml` 의 `scanGate` 값.

### cosign 컨테이너 + 이미지 서명 — `agent.podTemplates.kaniko` 확장

같은 pod 에 `cosign`(shell 포함 이미지, kaniko 와 동일하게 `sleep 99d` 로 유지) 컨테이너 추가. cosign 공식 이미지는 distroless 라 `sleep`/`sh` 가 없어 사이드카(agent 유지 + `exec`)로 못 쓴다 — kaniko 가 `:debug` 를 쓰는 이유와 동일. `ghcr-push` docker config 를 `/cosign/.docker` 로 마운트(`DOCKER_CONFIG` env) — 서명 아티팩트를 GHCR 에 push 하므로 registry 인증 필요.

- **`cosign-key` Secret 마운트** — `build` NS 의 Secret(key `cosign.key`+`password`)을 `/cosign/key` 로 마운트. 개인키는 파일(`cosign.key`), 비밀번호는 `COSIGN_PASSWORD` env(`secretKeyRef`)로 주입 — Jenkinsfile/스텝이 비번을 직접 다루지 않음.
- **digest 기준 서명** — `kanikoBuild` 가 `--digest-file` 로 기록한 push 이미지 digest 를 읽어 `cosign sign <image>@<digest>` 실행. 태그가 아닌 불변 digest 로 서명.
- **cosign v2 · 레거시 서명 포맷 · tlog 미사용** — 이미지는 자체 빌드 `ghcr.io/ggingggang/cosign:2.4.1` (`cosign-image/Dockerfile`: 공식 v2 distroless 에서 바이너리만 추출해 alpine 탑재). 사유: 공식 v2 이미지는 shell 이 없어 사이드카 불가, v3 는 레거시 포맷 서명이 제거됐는데 **Kyverno 는 v3 bundle 의 raw key 검증을 미지원**(kyverno#16267 — 수정 PR #16270 진행 중), bitnami 등 서드파티는 버전 태그를 내려 재현성 불가. v2 `--tlog-upload=false` 로 외부(Rekor) 호출 없이 자체완결 서명 — 검증측 Kyverno `rekor.ignoreTlog: true` 와 세트. bundle 지원이 Kyverno 에 릴리스되면 v3 복귀 검토.
- **podTemplate `imagePullSecrets: ghcr-pull`** — 자체 빌드 cosign 이미지가 private GHCR 소속이라 파드 이미지 pull 에 필요 (기존 공개 이미지들엔 불필요했던 항목).
- 서명 로직은 shared library `cosignSign` step 이 조립 (`jenkins-shared-library/vars/cosignSign.groovy`). `ci()` 가 `services.yaml` 의 `sign: true` 인 서비스에만 Sign 스테이지를 조건부로 넣는다(`when` 디렉티브) — Jenkinsfile 무수정으로 서명 대상 서비스가 늘어난다.

### JCasC seed — 환경변수 · 자격증명 · 라이브러리 · 잡

`JCasC.configScripts` 가 다섯 조각으로 분리:

- **`welcome-config`** — system message ("Source of truth = git").
- **`env-config`** — `globalNodeProperties` 로 `GH_ORG` 주입 (`containerEnv` 의 동명 env 를 JCasC `${GH_ORG}` 치환으로 받음). Jenkinsfile/seed 가 GHCR 경로·레포 URL 을 이 변수로 구성 → org 이전 시 한 곳만 변경. (도메인은 변수화 안 함 — `jenkinsUrl` 등에 이미 직접 박혀 공개값)
- **`credentials-config`** — `github-token` (usernamePassword, scope GLOBAL). 비밀번호는 `${GIT_PAT}` 치환 — `containerEnv` 의 `GIT_PAT` (Secret `jenkins-git-pat` key `token`) 에서 주입. 용도: Jenkins 가 [`k8s-gitops`](https://github.com/GGingGGang/k8s-gitops) 의 `manifests/<svc>` 에 image tag 를 bump (shared library `deployBump`). **credential 실값은 git 에 평문 ❌** — JCasC 는 `${GIT_PAT}` placeholder 만 보유, 실값은 Secret.
- **`library-config`** — Global Pipeline Library `shared` 등록 (`unclassified.globalLibraries`). `jenkins-shared-library` 레포를 modernSCM git retriever 로 로드, `defaultVersion: main`. **`implicit: false` 라 자동 로드 ❌** — Jenkinsfile 이 `@Library('shared') _` 로 명시 호출해야 적재. 공용 step(예: `kanikoBuild`)을 앱 레포 3곳이 중복 보유하지 않게 하는 단일 출처.
- **`jobs-config`** — `job-dsl` 로 잡을 선언적 생성. UI 클릭 잡 생성은 emptyDir 라 재기동 시 증발하므로 무효. `organizationFolder('services')` 1개가 레포를 **자동 발견** — 잡을 명세하지 않고 발견 규칙만 명세:
  - `repoOwner('${GH_ORG}')` + `sourceRegexFilter('svc-.*')` — 소유자의 레포 중 `svc-` prefix 만 골라 각각 multibranch 파이프라인 생성. 인벤토리를 git 에 손으로 나열하지 않고 GitHub 스캔으로 재도출 → emptyDir(stateless) 철학과 정합(job 목록조차 상태로 안 들고 boot 마다 derive).
  - `workflowMultiBranchProjectFactory { scriptPath('Jenkinsfile') }` — 발견된 레포 루트 `Jenkinsfile` 로 파이프라인 정의 (정의는 앱 레포 소유).
  - `gitHubBranchDiscovery(strategyId 1)` 브랜치만 발견(PR 미포함) · `periodicFolderTrigger('15m')` 웹훅 유실·신규 레포 폴백 재스캔 · `orphanedItemStrategy` 사라진 브랜치/레포 잡 자동 정리.
  - `queue('services')` — job-dsl 은 폴더를 **생성만** 하고 첫 Scan Organization 을 스스로 돌리지 않는다. emptyDir 콜드부트 직후는 잡 0개 상태라 webhook 이 와도 매칭 대상이 없으므로, JCasC 적용(부팅·reload) 시마다 스캔을 큐잉해 잡 인벤토리를 사람 개입 없이 재도출.

> 앱 추가 계약: 레포명 `svc-<service>` (예: `svc-core`, `svc-auth`) + 루트 `Jenkinsfile`. 이름 규칙만 지키면 다음 스캔에 자동 편입 — `jobs-config` · 인프라 무수정. `svc-` prefix 가 인프라/라이브러리 레포(`oci-always-free-k8s`/`jenkins-shared-library`/`k8s-gitops`)를 멤버십에서 자동 배제. 타입(front/back/batch)은 멤버십 regex 에 안 넣고 각 레포 Jenkinsfile(shared library 호출)이 처리 — 타입 늘어도 regex 무수정.

> 라이브러리·발견이 `${GH_ORG}` 로 소유자를 구성 → org 이전 시 `containerEnv` 한 곳만 변경. (`credentials-config` 의 username 은 리터럴 — org 이전 시 함께 변경.)

> 트리거 등록 방식: `organizationFolder` 는 발견한 레포에 훅 자동 등록 가능 — `github-token` 에 `admin:repo_hook` scope 면 스캔 시 레포별 webhook 생성, 없으면 `periodicFolderTrigger('15m')` 폴백(최대 15분 지연). 개인 계정은 계정-레벨 훅이 없어 레포별 훅 or 폴백, 진짜 org 는 org-레벨 단일 훅 가능. 종착지는 GitHub App.

GHCR 레포 경로는 **소문자 강제** — GitHub 계정명에 대문자가 있으면 Jenkinsfile 에서 `${env.GH_ORG.toLowerCase()}` 로 이미지 경로 구성(git clone URL 은 원본 케이싱 유지 가능).

### `numExecutors: 0` on controller

controller는 빌드 안 함. agent Pod만 빌드 → controller는 *오케스트레이션 전용* 격리. controller resource 보호 + 빌드 격리.

### RBAC — controller `cicd`, 빌드 `build`

`rbac.yaml` 구조:

- `cicd/jenkins` SA — controller 신원. agent Pod 관리 권한 두 곳에 분배:
  - `cicd` NS — 일반 빌드 agent Pod CRUD
  - `build` NS — Kaniko 빌드 Pod CRUD (cross-NS RoleBinding)
- `build/kaniko-builder` SA — 빌드 Pod 신원. `automountServiceAccountToken: false`. k8s API 권한 0건

권한 경계 narrative:

- controller (`jenkins` SA) 는 *Pod 만들 권한* 만 가짐 — image 자체에 대한 권한 ❌
- 빌드 Pod (`kaniko-builder` SA) 는 *GHCR push token* 만 가짐 — Pod 만들 권한 ❌
- 둘 다 `app` NS 권한 0건 — 배포는 git commit (manifest 패턴) 으로만

manifest commit 패턴: Jenkins 는 *k8s API 직접 호출 ❌*, *git push (`k8s-gitops` `manifests/<svc>` 에 image tag bump — shared library `deployBump`)* 만. ArgoCD 가 git diff 감지해서 `app` NS 에 적용 → *권한 경계가 git 레벨에서 강제됨*.

### HTTPRoute — admin UI 는 parked, webhook 만 public

`httproute.yaml` 한 파일에 두 HTTPRoute 리소스(`---` 구분) — *접근 경로는 호출자가 누구냐로 결정*한다. ArgoCD `jenkins-httproute` Application(`directory.include: httproute.yaml`)이 이 파일을 sync 하므로 라우트는 GitOps 로 관리. **별도 파일/Application 신설 ❌** — app-of-apps 의 단일 `httproute.yaml` include 패턴을 따른다(별도 파일은 include 밖이라 ArgoCD 가 adopt 못 함). 독립 on/off 는 파일이 아니라 `---` 로 나뉜 *리소스* 단위 주석 토글로 확보.

- **admin UI (`jenkins.ggang.cloud`, 전체 path)** — tailnet 컷오버로 **주석 처리(parked)**, 렌더링 0. admin은 tailnet ClusterIP 전용. 운영자는 tailnet 노드가 될 수 있으니 컨트롤 표면은 사설로.
- **webhook (`ci-hook.ggang.cloud`, `/github-webhook/` 만)** — **active**. GitHub(SaaS)는 tailnet 노드가 될 수 없으니 이벤트 인입은 public 일 수밖에 없다. 단 노출은 *한 경로*로 좁히고 HMAC 으로 게이트.

#### Webhook — path-scoped public 인입

`public-gateway` 의 `https-wildcard` listener 가 이미 `*.ggang.cloud` 를 받으므로 **게이트웨이 수정 0** — 새 서브도메인은 HTTPRoute 만 추가하면 된다 (와일드카드 리스너의 설계 목적). `ci-hook.ggang.cloud` 는 `*.ggang.cloud` 의 부분집합이라 동일 wildcard cert 로 GitHub 의 TLS 검증이 깨끗하게 통과 — "Disable SSL verification" 불필요.

보호 레이어:

1. **경로 스코프** — HTTPRoute 가 `/github-webhook/` 만 매칭. `/`·`/script` 등은 매칭 룰 없어 404 → admin UI 는 public 으로 안 샘.
2. **HMAC (설계, 미적용)** — `gh-webhook-secret` 을 GitHub repo webhook 설정의 Secret 필드 + Jenkins GitHub plugin 양쪽에 등록하면 `X-Hub-Signature-256` 검증으로 서명 없는 요청을 거부할 수 있다. **현재 이 Secret 을 생성하거나 JCasC 에 연결하는 매니페스트/설정이 레포에 없음** — 미구현 상태. 지금은 경로 스코프(1번)만으로 방어.
3. *(선택, 미적용)* GitHub hooks IP 대역(`api.github.com/meta`) allowlist — defense-in-depth. 대역 변동 유지비 있어 1·2 로 충분, 후속 검토.

`cicd` 가 ambient enrolled 라 게이트웨이→jenkins hop 은 ztunnel L4 mTLS. 엣지 TLS 종료(wildcard cert) + 내부 mTLS 둘 다 충족. external-dns 가 `hostnames` 를 source 로 `ci-hook.ggang.cloud` A 레코드 자동 등록.

> 트리거를 webhook 으로 둔 이유: SCM polling 은 public 표면 0 이지만 지연·낭비. webhook-via-Gateway 는 GitHub Actions 에 tailscale 을 심는 안티패턴(앱 레포마다 네트워크 신원 분산)을 피하면서 이벤트 드리븐을 얻는다 — 앱 레포엔 tailscale 0, 트리거 설정은 GitHub repo settings(git 밖).

### Secret 운영 — `ghcr-push` · `jenkins-git-pat` 선행, 나머지는 앱 레포 시점

본 setup 에 필수:

- `ghcr-push` (Kaniko 빌드용, `build` NS) — type `kubernetes.io/dockerconfigjson`
- `ghcr-pull` (`build` NS) — podTemplate `imagePullSecrets` 용. 자체 빌드 cosign 이미지(`ghcr.io/ggingggang/cosign`)가 private GHCR 소속이라 빌드 파드의 이미지 pull 에 필요. 앱 NS 의 동명 Secret 을 복사.
- `cosign-key` (이미지 서명용, `build` NS) — key `cosign.key`(암호화 개인키) + `password`. cosign 컨테이너가 파일 마운트 + `COSIGN_PASSWORD` env 로 소비. 생성: `cosign generate-key-pair` → `kubectl create secret generic cosign-key -n build --from-file=cosign.key --from-literal=password=<비번>`. 공개키(`cosign.pub`)는 Kyverno 검증용으로 별도 보관.
- `jenkins-git-pat` (`cicd` NS, key `token`) — `containerEnv` 의 `GIT_PAT` → JCasC `credentials-config` 의 `github-token` 비밀번호. 매니페스트 bump push 용. **미존재 시 controller pod 가 `secretKeyRef` 로 기동 실패.**

앱 레포 등장 시점에 추가 도입:

- `ghcr-pull` — 앱 Pod (`app` NS) `imagePullSecrets`
- `gh-webhook-secret` — GitHub Webhook HMAC SHA-256 검증. **설계만 존재, 실제 Secret 생성/JCasC 연결 미구현** (위 §HMAC 참조)

모두 Vault Agent Injector 또는 GitHub App 으로 이관 예정.

## 5. 주의 사항

### JCasC 적용 실패 시

```bash
kubectl logs -n cicd jenkins-0 -c jenkins | grep -iE "casc|configuration-as-code|error"
```

흔한 원인:
- `configScripts` YAML 들여쓰기 깨짐 → multi-line literal block (`|`) 사용 강제
- plugin 누락 — `configuration-as-code` plugin 명시 + chart 버전과 호환 확인
- `JCasC.defaultConfig: true` + 동일 key 중복 → `ConfiguratorConflictException`. chart 기본 JCasC가 채우는 키(`jenkins.numExecutors`, `unclassified.location.url/adminAddress` 등)는 `configScripts`에서 재정의 ❌. 대신 chart value(`controller.numExecutors`, `controller.jenkinsUrl`, `controller.jenkinsAdminEmail`)로 설정

### emptyDir 빌드 history 손실

빌드 메타데이터는 controller pod 재시작 시 모두 손실. *수용 가능*:
- 빌드 결과물(image): GHCR에 영구 보존
- 빌드 로그: observability stack의 Loki에 수집 (Alloy — 도입 예정)
- 빌드 트리거 이력: GitHub commit + webhook 로그
- 파이프라인 정의: git (Jenkinsfile)

→ source of truth가 *git + GHCR + Loki* 분산. controller PV ❌도 무손실.

### admin 비밀번호 회전

`jenkins-admin-fixed` Secret 의 자격은 *plain text* (git 밖, §2 참조). 비번 변경은 Secret 갱신 + pod 재기동. 운영 진입 시:

1. JCasC `securityRealm` 을 GitHub OAuth (또는 Dex) 로 전환 — 보안 강화 단계
2. `admin` 사용자 비활성화 또는 강력한 비밀번호로 변경

### Gateway listener attach 실패 시

```bash
kubectl describe httproute jenkins-webhook -n cicd | grep -A5 "Conditions\|Parents"
```

`ResolvedRefs: False` 또는 `Accepted: False` 시 원인:
- Gateway `public-gateway` 의 `allowedRoutes.namespaces.from: All` 확인
- `sectionName: https-wildcard` 가 Gateway listener 이름과 정확히 일치하는지 확인
- backend service `jenkins` 가 같은 `cicd` namespace에 존재하는지 확인

### prometheus integration

현재 `prometheus.enabled: false`. kube-prometheus-stack 은 도입 완료(`../monitoring/`) — 활성화 시 `prometheus.serviceMonitor.enabled: true` + ServiceMonitor 자동 등록. 빌드 큐 길이, agent 생성 시간, 빌드 실패율 메트릭 수집.

### Kaniko 빌드 실패 디버깅

```bash
kubectl get pods -n build
kubectl logs -n build <kaniko-pod> -c kaniko
kubectl describe pod -n build <kaniko-pod>
```

흔한 원인:

- `ghcr-push` Secret 누락 또는 type 불일치 → `unauthorized: authentication required`
  - `kubectl get secret ghcr-push -n build -o jsonpath='{.type}'` 가 `kubernetes.io/dockerconfigjson` 인지 확인
- **빌드 성공인데 잡이 안 끝남(무한 hang)** → kaniko 가 shell 파괴 → durable-task 종료 마커 못 씀. `--ignore-path=/busybox --ignore-path=/home/jenkins` 누락 여부 확인 (위 Kaniko podTemplate 결정 참조)
- **GHCR push 시 `repository can only contain [a-z0-9_-./]`** → 이미지 경로에 대문자. org/레포명 소문자화 (`toLowerCase()`)
- PSA 거부 → Pod 생성 실패. `build` NS 가 `privileged` enforce 인지 확인
- base image multi-arch 미보장 → `no image found ... architecture "arm64"`. alpine 등 amd64 단일 아키 태그 회피, 멀티아치 태그 사용. registry 매니페스트로 아키 확인(위 Agent 결정 참조)
- OOMKilled (exit 137) → cache 미사용 시 흔함. `--cache=true` + `--snapshot-mode=redo` 적용. limit `2Gi` 부족하면 chart values 의 podTemplate memory limit 상향
- Jenkins controller 가 `build` NS 에 Pod 못 만듦 → `rbac.yaml` 의 `jenkins-builder` RoleBinding 적용 확인
- **agent pod `FailedScheduling: Insufficient cpu`** → 노드 requests 장부 포화(실사용 아님, `kubectl top nodes` 로 괴리 확인). 좀비 pod(`ImageInspectError` 등)가 requests 점유 시 `kubectl delete pod -n build <pod> --force --grace-period=0`. requests 는 실측 기반 하향(controller/kaniko 200m)

### 단일 인스턴스 RTO

controller pod 단일. node 장애 시:
- 정상: ~3분 (k8s scheduler가 다른 노드로 재배치 + JCasC reload + plugin 로드)
- 노드 둘 다 장애: terraform apply 후 재설치 (~30분)

Jenkins 는 ArgoCD `jenkins` Application 으로 관리되므로 cluster 재구축 시 ArgoCD sync 한 번에 복구.
