# kyverno

정책 엔진. 현재 용도: **이미지 서명 admission 검증** — 지정된 네임스페이스의 `ghcr.io/ggingggang/svc-*` 이미지 서명을 검사하는 게이트. Trivy(스캔) → cosign(서명) → Kyverno(검증) 공급망 체인의 마지막 조각.

## 1. 전제 조건

- cosign 서명 체계 가동 — svc 레포 CI 의 `cosignSign` 스텝이 GHCR 에 레거시 포맷(`.sig` 태그) 서명 부착 ([jenkins-shared-library](https://github.com/GGingGGang/jenkins-shared-library) README 참조)
- 서명 검증용 공개키 `cosign.pub` 보유 (키페어 생성 시 산출물 — 공개키라 git 커밋 안전)
- ArgoCD 플랫폼 app-of-apps 가동 (`../argocd/`)
- `kyverno` NS + PSA 라벨 (`../../infra/namespaces/`)
- `ghcr-pull` Secret 이 `kyverno` NS 에 존재 — GHCR 패키지가 private 이라 서명 bundle 조회에 registry 자격증명 필요 (정책의 `imageRegistryCredentials.secrets`)

## 2. 설치

ArgoCD Application 2개가 담당 (`../argocd/apps/kyverno.yaml` — 차트, `kyverno-policies.yaml` — 정책):

1. `policies/verify-image-signature.yaml` 에 등록된 공개키가 CI 서명 키와 일치하는지 확인하고, 키가 바뀌었다면 `publicKeys` 를 갱신
2. `ghcr-pull` Secret 을 kyverno NS 로 복사 (서명 bundle 조회용):

```bash
kubectl create secret generic ghcr-pull -n kyverno \
  --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson="$(kubectl get secret ghcr-pull -n auth -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)"
```

3. 변경사항을 Git에 반영하면 root app 이 Application 2개를 관리한다. 자식 Application에는 자동 sync 설정이 없으므로 차트(wave 6)를 먼저, 정책(wave 7)을 다음에 수동 sync 한다. 아래 명령은 `kubernetes/platform/kyverno` 디렉터리 기준이다. Argo CD CLI는 `cicd`의 Argo CD에 로그인되어 있어야 한다.

```bash
kubectl apply -f ../../infra/namespaces/namespaces.yaml   # kyverno NS 선행
argocd app sync kyverno
argocd app sync kyverno-policies
```

## 3. 검증

```bash
kubectl get pods -n kyverno                    # admission + reports controller Running
kubectl get clusterpolicy                      # verify-svc-image-signature Ready=True

# 정책은 background: false — 기존 리소스의 백그라운드 검사는 하지 않음.
# 대상 이미지의 새 Pod admission 이후 리포트를 확인:
kubectl get policyreport -n auth
kubectl describe policyreport -n auth | grep -B2 -A6 verify-svc-image-signature
```

## 4. 결정

- **Enforce** — 정책에 매칭되는 이미지의 서명이 없거나 검증에 실패하면 admission 에서 거부한다. 라벨이 없거나 이미지 패턴이 일치하지 않으면 이 정책의 서명 검증 대상이 아니다.
- **스코프는 `namespaceSelector`(라벨 `verify-images: "true"`) + `ghcr.io/ggingggang/svc-*` 와일드카드** — `jenkins-shared-library`의 `ci()`가 `services.yaml` `defaults.sign: true`로 전 서비스 서명을 이미 깔고 시작해서(신규 서비스도 명시적으로 `sign: false`를 안 주면 자동 서명), 정책 스코프도 정적 나열 대신 라벨 멤버십으로 따라가게 함. 현재 라벨이 붙은 NS는 `core`, `batch`, `auth`, `notify`, `web`이다. 신규 NS에 라벨을 추가하더라도 이미지가 이 패턴에 일치해야 검증된다.
- **`mutateDigest`/`verifyDigest`: false** — 현재 ClusterPolicy는 이미 `Enforce`이며, 배포 매니페스트가 태그(git SHA) 참조를 사용하므로 digest mutation과 digest 참조 요구를 모두 끈다. 서명 검증은 유지하지만 이미지 참조를 digest로 복원하거나 강제하지 않는다. digest pinning을 도입하려면 정책과 배포 매니페스트를 함께 변경해 검증한다.
- **기본(Cosign) 검증 타입 — `type: SigstoreBundle` 미사용** — Kyverno 1.18 은 SigstoreBundle 에서 raw 공개키(`keys.publicKeys`)를 **조용히 무시**해 검증 불가 (kyverno#16267·#14233, 수정 PR #16270 진행 중 — tlog 유무 불문 "no matching signatures found" 실측). 서명을 cosign v2 레거시 포맷으로 맞추고 성숙한 기본 경로를 사용. bundle 의 key 지원이 릴리스되면 v3/bundle 복귀 검토.
- **tlog 미사용 · `rekor.ignoreTlog: true`** — 서명이 `--tlog-upload=false`(자체완결, 공개 Rekor 미의존)라 검증도 tlog 조회를 끔. 이 설정 없으면 Rekor 조회 실패로 검증이 깨짐.
- **`imageRegistryCredentials.secrets: [ghcr-pull]` (정책 레벨)** — private GHCR 서명 조회용 자격증명을 정책에 지정한다. 차트 values에는 `existingImagePullSecrets` 설정이 없다.
- **background/cleanup controller off** — mutate-existing/generate/cleanup 정책 미사용. 24GB 예산에서 admission + reports 만 상주.
- **admission replicas 1** — HA 보다 RAM 우선 (다른 플랫폼 컴포넌트와 동일 기조).

## 5. 주의 사항

- **신규 NS 온보딩 시 순서**: `verify-images: "true"` 라벨을 붙이기 전에 해당 서비스가 서명된 이미지로 배포되는지 먼저 확인 — Enforce 상태에서 미서명 이미지로 라벨을 붙이면 다음 재시작/재스케줄 때 파드 생성이 바로 거부됨.
- 정책 match는 라벨이 붙은 NS의 Pod를 대상으로 한다. 실제 webhook 선택 범위와 장애 시 영향은 생성된 webhook 설정과 다른 정책에도 좌우되므로 운영 환경에서 확인한다.
- 키 로테이션 시 정책 `publicKeys` 도 함께 교체 — 구 키로 서명된 이미지는 새 키로 검증 실패.
- **`ghcr-pull` 토큰 만료 = 검증 실패 및 admission 거부.** 정책이 `Enforce`이므로 토큰 로테이션 시 kyverno NS 사본도 함께 갱신해야 한다. 시크릿 중앙화(OpenBao) 이관 시 단일 소스로 일원화 대상이다.
