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
- Helm chart `5.10.3`, Jenkins `2.580.2-jdk21` (Java 21), inbound agent `3395.v6e5377b_0fb_3c-1-jdk21`.

### 버전을 변경하는 위치

| 대상 | 파일 | 설정 |
| --- | --- | --- |
| Jenkins 본체 | `values.yaml` | `controller.image.tag` |
| Helm 차트 | `../argocd/apps/jenkins.yaml` | Helm source의 `targetRevision` |
| 플러그인 전체 버전 | `values.yaml` | `controller.installPlugins` |
| 기본 빌드 에이전트 | `values.yaml` | `agent.image.tag` |
| Kaniko Pod의 Jenkins 에이전트 | `values.yaml` | `agent.podTemplates.kaniko`의 `jnlp.image` |

```bash
rg -n 'tag:|installPlugins:|installLatestPlugins:|initializeOnce:|inbound-agent:' values.yaml
rg -n 'targetRevision:' ../argocd/apps/jenkins.yaml
```

차트 버전은 배포 템플릿과 기본 설정을 선택한다. 본체 이미지 태그는 `controller.image.tag`에 별도로 고정한다. `installPlugins`를 삭제하거나 주석 처리하면 차트의 기본 플러그인 목록이 적용된다. Argo CD는 Helm 템플릿을 YAML로 렌더링해 동기화하므로, 다른 Application의 Kustomize 구성과 함께 운영할 수 있다.

2026-10-29 기준 공식 차트 저장소의 최신 버전 `5.10.3`과 LTS `2.580.2`를 확인했다. 본체와 에이전트의 Java 21 이미지에 `linux/arm64` 매니페스트가 있음을 확인했고, 플러그인 84개를 Jenkins `2.580.2` 기준으로 해석한 뒤 전체 버전을 고정했다. 의존성 검증은 `--latest false --no-download --list`로 수행하며 실제 클러스터 기동 검증과 구분한다.

근거: [공식 차트 저장소](https://charts.jenkins.io/), [Jenkins LTS 변경 이력](https://www.jenkins.io/changelog-stable/), [2.580 업그레이드 안내](https://www.jenkins.io/doc/upgrade-guide/2.580/), [Argo CD의 Helm 지원](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/).

## 2. 설치

### Trivy 노드별 캐시

Trivy만 노드의 `/var/lib/trivy-cache`를 컨테이너의 `/var/cache/trivy`로 마운트한다. `hostPath: DirectoryOrCreate`로 경로가 없으면 kubelet이 생성한다. PV/PVC, StorageClass, 노드 라벨, subPath는 필요 없다. 기존 `build` namespace의 PSA privileged 정책에서 사용한다.

적용 순서:

1. `jenkins-shared-library`의 `TRIVY_CACHE_ROOT` 지원 변경을 먼저 커밋·푸시한다. 변수가 없는 기존 빌드는 기존 임시 캐시를 사용한다.
2. 이 저장소의 Jenkins values 변경을 커밋·푸시한다. 실행 중 빌드가 끝난 뒤 Argo CD의 `jenkins` 앱을 수동 Sync한다.
3. 새 빌드부터 배치된 노드의 캐시를 사용한다. 같은 노드에서 같은 작업을 재실행해 DB 다운로드와 Image Scan 시간을 비교한다.

```bash
argocd app diff jenkins
argocd app sync jenkins
kubectl -n build get pods -o wide
# 실행 중인 빌드 Pod 이름을 지정한다.
kubectl -n build exec "$BUILD_POD" -c trivy -- du -sh /var/cache/trivy
```

노드 A/B는 각각 독립된 캐시를 가진다. 각 노드·Jenkins 작업의 최초 실행에는 DB를 다운로드하며 이후 재사용한다. DB 갱신 시 재다운로드는 정상이다. 업데이트를 끄지 않는다.

캐시는 `<root>/<SHA256(JOB_NAME)>`으로 나눈다. 다른 작업의 병렬 스캔은 별도 디렉터리를 사용하며, 같은 작업은 `ci()`의 `disableConcurrentBuilds()`로 직렬화한다. step을 직접 호출하는 파이프라인도 같은 작업의 동시 실행을 막아야 한다.

Trivy는 root 소유 hostPath 캐시를 쓰기 위해 UID 0으로 실행하며, 다른 UID의 Jenkins 에이전트가 만든 실행·로그 파일에 접근하도록 `drop: ["ALL"]`에 `add: ["DAC_OVERRIDE"]`만 추가한다. 이 capability는 마운트된 파일의 일반 소유권·접근 권한 검사를 우회할 수 있으므로 Trivy 컨테이너에만 부여한다. `drop: ["ALL"]`만 남기면 `Image Scan`의 `sh`가 로그 없이 대기할 수 있다. [Jenkins의 컨테이너 간 UID 문제 안내](https://plugins.jenkins.io/kubernetes/#plugin-content-pipeline-sh-step-hangs-when-multiple-containers-are-used).

노드 캐시는 잃어도 다시 다운로드하면 되므로 특정 노드로 빌드를 고정하지 않는다. hostPath에는 용량 제한이나 자동 정리가 없으며 사용량이 Pod ephemeral-storage 제한으로 관리되지 않는다. 노드 디스크 여유를 확인하고 오래된 작업 캐시는 빌드가 없는 유지보수 시간에 정리한다. 기존 `/var/lib/trivy-cache`가 다른 용도나 심볼릭 링크로 사용되는 노드는 사전에 경로를 정리해야 한다.

캐시 도입 전으로 롤백하려면 values의 `TRIVY_CACHE_ROOT`, 캐시 volumeMount와 hostPath volume, Trivy에 추가한 `securityContext`를 함께 제거해 Jenkins를 동기화한다. `drop: ["ALL"]`만 남기지 않는다. 새 Pod는 임시 캐시로 돌아가며 노드에 남은 캐시는 자동 삭제되지 않는다.

근거(2026-10-14 확인): [Kubernetes hostPath](https://kubernetes.io/docs/concepts/storage/volumes/#hostpath), [Trivy 캐시](https://trivy.dev/docs/latest/configuration/cache/).

#### 캐시 재사용 실측 — 2026-10-14

`services/svc-auth/main`의 연속 빌드에서 확인했다. Trivy `0.72.0`, 이미지 태그 `940e6cc78a01fed5c21852df081d6a61a7a47095`, 복구 커밋 `1d5f29d` 적용 상태다. 스캔 정책과 DB 자동 업데이트는 유지했다.

| 빌드 | 실행 노드 | DB 다운로드 | Image Scan | 전체 빌드 | 결과 |
| --- | --- | --- | ---: | ---: | --- |
| #31 | A | 있음 — 첫 캐시 생성 | 98.281초 | 248.412초 | SUCCESS |
| #32 | B | 있음 — 다른 노드의 첫 캐시 생성 | 80.915초 | 215.082초 | SUCCESS |
| #33 | A | 없음 — 기존 캐시 재사용 | 27.338초 | 178.719초 | SUCCESS |

같은 노드의 #31 → #33에서 Image Scan은 **70.943초(72.2%)**, 전체 빌드는 **69.693초(28.1%)** 단축됐다. #33 로그에 작업별 `TRIVY_CACHE_DIR` 설정과 스캔 완료가 있고 DB 다운로드는 없었다. 캐시 재사용은 확인됐으며, 수치는 이번 실행 쌍의 관측값이다. DB 갱신이나 캐시 삭제 후에는 다운로드가 다시 발생할 수 있다.

근거: 2026-10-14 14:35 KST에 수집한 Jenkins #31~#33 빌드 로그와 `wfapi/describe` 응답, 각 빌드 Pod의 Kubernetes `Scheduled` 이벤트. 시간은 스캔 명령만이 아니라 리포트 생성·게시를 포함한 `Image Scan` 단계 전체를 기준으로 했다.

### Jenkins 설치

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

helm install jenkins jenkins/jenkins -n cicd --version "5.10.3" -f values.yaml --wait

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

- **분배 정합** — 현재 `oci-bv` PVC는 NATS JetStream과 Prometheus가 사용하며, OpenBao는 `emptyDir` 기반 Raft. Jenkins 상태는 Git에서 재생성하므로 PVC가 불필요
- **GitOps 단일 진실** — 모든 설정이 `values.yaml` JCasC seed에 박힘. UI 클릭으로 영구 변경 ❌ (UI 변경은 next reload에서 git값으로 덮임)
- **DR narrative** — pod 날아가도 git이 source of truth. PV 복원 불필요
- **trade-off**: 빌드 history 손실 (재시작마다). 다만 빌드 메타데이터는 git + GHCR + Loki(observability 도입 시)에 영구 보존

### 단일 인스턴스 controller

HA controller는 Jenkins 라이선스/플러그인 호환성 폭증. 본 환경은 Always Free 24GB RAM에서 *동작/재현성*이 *고가용성*보다 우위. RTO는 "JCasC 재로드 + agent pod 재생성"으로 분단위.

### Plugins 전체 pin + `installLatestPlugins: false`

JCasC의 Job DSL과 GitHub organization folder, Pipeline, Kubernetes agent, `readYaml`, `timestamps`, `publishHTML`에 필요한 플러그인과 전이 의존성 84개를 `installPlugins`에 명시한다. 본체 버전만 올리거나 차트 기본 플러그인 네 개만 설치하면 필요한 기능이 빠질 수 있다.

`installLatestPlugins: false`는 의존성의 최소 요구 버전을 사용하게 한다. 이번 구성은 해석된 의존성까지 전부 고정하므로 같은 목록을 다시 검사할 수 있다. `true`를 유지하면 낮게 고정한 플러그인과 새로 선택된 의존성 사이에 버전 충돌이 생길 수 있다.

업그레이드 순서:

1. 새 Jenkins 본체 버전을 정하고 필요한 직접 플러그인을 별도 목록에 적는다.
2. 공식 설치 도구로 새 본체 기준의 의존성을 해석한다.

   ```bash
   jenkins-plugin-cli --jenkins-version 2.580.2 \
     --plugin-file plugins-requested.txt --latest true --no-download --list
   ```

3. 해석된 전체 플러그인과 버전을 `installPlugins`에 반영한다. 동일 목록을 `name:version` 형식의 `plugins.txt`로 준비해 고정된 버전을 다시 검사한다.

   ```bash
   jenkins-plugin-cli --jenkins-version 2.580.2 \
     --plugin-file plugins.txt --latest false --no-download --list
   helm pull jenkins/jenkins --version 5.10.3 --destination /tmp
   helm lint /tmp/jenkins-5.10.3.tgz -f values.yaml
   helm template jenkins jenkins/jenkins --version 5.10.3 \
     -n cicd -f values.yaml > /tmp/jenkins-rendered.yaml
   ```

4. 아래 `emptyDir` 주의 사항에 따라 데이터를 보존한 뒤 Git에 반영한다. Argo CD에서 차트와 values 변경을 동기화하고 기동 상태를 확인한다.

   ```bash
   argocd app diff jenkins
   argocd app sync jenkins
   kubectl rollout status -n cicd statefulset/jenkins --timeout=300s
   kubectl logs -n cicd jenkins-0 -c init --tail=60
   ```

개별 플러그인 버전만 임의로 올리지 말고, 본체와 전체 의존성 목록을 함께 검증한다. `--no-download` 검사는 의존성 검사이며 실제 플러그인 다운로드와 Jenkins 기동 성공을 보장하지 않는다.

### 재부팅 후 초기화와 `emptyDir`

`controller.initializeOnce: true`로 같은 Pod의 Jenkins home에 `initialization-completed` 표식을 남긴다. 완료된 init가 노드 재부팅 후 다시 실행될 때 플러그인 복사 단계에 들어가지 않도록 한다. 차트의 `yes n | cp -i`가 기존 파일의 덮어쓰기를 거부하면 실패 코드로 종료될 수 있기 때문이다.

현재 home은 `emptyDir`이므로 이 표식은 같은 Pod의 볼륨이 남아 있는 동안만 유지된다. Pod가 교체되면 home과 플러그인 볼륨이 새로 만들어져 초기화를 다시 수행한다. 초기화가 완료되기 전에 중단된 경우에는 표식이 없으므로 이전 실패 로그와 복사 대상부터 확인한다. `initializeOnce`만으로 모든 부분 실패를 처리할 수는 없다.

JCasC가 설정을 다시 생성하더라도 빌드 기록, 작업 공간, 수동 변경이 복원되는 것은 아니다. Pod 교체 전에 필요한 home 데이터를 별도로 백업한다. 향후 PVC로 바꾸면 표식이 Pod 교체 후에도 유지되므로 플러그인 업그레이드 때 초기화 정책도 다시 검토한다.

근거: 차트 `5.10.3`의 `templates/config.yaml`, `controller.initializeOnce` 설명과 [플러그인 설치 도구](https://github.com/jenkinsci/plugin-installation-manager-tool), [GNU coreutils 변경 이력](https://raw.githubusercontent.com/coreutils/coreutils/master/NEWS). GNU `cp -i`의 종료 코드 변경은 2023-03-20의 9.2 변경 사항으로 2년을 초과한 자료이며, 사용 중이던 실제 init 스크립트와 실패 로그를 함께 확인했다.

### Agent — Kubernetes plugin + `containerCap: 2`

빌드 agent는 동적 Pod (`agent.enabled: true`). 동시 빌드 2개로 제한 (24GB RAM 환경 보호). 빌드 종료 시 Pod 자동 삭제 — stateless.

agent image 태그는 `3395.v6e5377b_0fb_3c-1-jdk21`로 고정한다. 이 태그의 공식 registry 매니페스트에 `linux/amd64`와 `linux/arm64`가 포함되어 있음을 확인했다. controller도 Java 21 이미지를 사용한다. registry 매니페스트 확인 명령:

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

위 `/kaniko/executor` 옵션들은 shared library `kanikoBuild` step 이 내부적으로 조립한다 (`jenkins-shared-library/vars/kanikoBuild.groovy`). 앱 레포 `Jenkinsfile` 은 raw kaniko 호출도, 개별 스테이지 나열도 하지 않고 `ci()` 메타 step 하나로 전체 파이프라인(Test → Build & Push → Image Scan → Sign → Bump)을 조립한다:

```groovy
@Library('shared') _

ci(service: 'core')
```

서비스별로 갈리는 값(스캔 게이트, 서명 여부)과 언어별 Test 게이트(테스트 이미지·커맨드)는 Jenkinsfile 이 아니라 shared library 의 `resources/ci/services.yaml` 한 파일에 모여 있다 — 새 서비스 추가·설정 변경이 그 파일 한 줄로 끝나고 `ci.groovy`/Jenkinsfile 은 무수정. `services.yaml` 파싱에 `installPlugins` 의 `pipeline-utility-steps`(`readYaml` 스텝) 필요. Test 스테이지가 쓰는 `test` 컨테이너는 본 `values.yaml` 의 kaniko podTemplate 이 아니라 `ci()` 가 `inheritFrom` + yaml merge 로 빌드 시점에 얹는다 — JCasC 템플릿엔 없는 컨테이너가 파드에 하나 더 뜨는 게 정상.

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
- **`credentials-config`** — `github-token` (usernamePassword, scope GLOBAL). 비밀번호는 `${GIT_PAT}` 치환 — `containerEnv` 의 `GIT_PAT` (Secret `jenkins-git-pat` key `token`) 에서 주입. 용도: Jenkins가 [`k8s-gitops`](https://github.com/GGingGGang/k8s-gitops)의 `manifests/<svc>` image tag 변경을 GitOps `main`에 직접 push하는 것(shared library `deployBump`). **credential 실값은 Git에 평문으로 보관하지 않는다.** JCasC는 `${GIT_PAT}` placeholder만 보유하고 실값은 Secret에서 주입한다.
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

manifest 변경 패턴: Jenkins는 Kubernetes API를 직접 호출하지 않으며, shared library `deployBump`로 `k8s-gitops`의 `main`에 image tag 변경을 직접 push한다. Jenkins 성공은 GitOps push까지를 뜻하며 실제 배포 완료는 ArgoCD의 Sync와 Health 상태로 확인한다.

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
- `jenkins-git-pat` (`cicd` NS, key `token`) — `containerEnv` 의 `GIT_PAT` → JCasC `credentials-config` 의 `github-token` 비밀번호. GitOps `main`에 매니페스트 bump를 push하는 용도. **미존재 시 controller pod 가 `secretKeyRef` 로 기동 실패.**

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

현재 `prometheus.enabled: false`. kube-prometheus-stack 은 도입 완료(`../monitoring/kps/`) — 활성화 시 `prometheus.serviceMonitor.enabled: true` + ServiceMonitor 자동 등록. 빌드 큐 길이, agent 생성 시간, 빌드 실패율 메트릭 수집.

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
