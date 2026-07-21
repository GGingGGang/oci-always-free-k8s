# kyverno

정책 엔진. 현재 용도: **이미지 서명 admission 검증** — CI(cosign)가 서명한 이미지만 통과시키는 게이트. Trivy(스캔) → cosign(서명) → Kyverno(검증) 공급망 체인의 마지막 조각.

## 1. 전제 조건

- cosign 서명 체계 가동 — svc 레포 CI 의 `cosignSign` 스텝이 GHCR 에 레거시 포맷(`.sig` 태그) 서명 부착 ([jenkins-shared-library](https://github.com/GGingGGang/jenkins-shared-library) README 참조)
- 서명 검증용 공개키 `cosign.pub` 보유 (키페어 생성 시 산출물 — 공개키라 git 커밋 안전)
- ArgoCD 플랫폼 app-of-apps 가동 (`../argocd/`)
- `kyverno` NS + PSA 라벨 (`../../infra/namespaces/`)
- `ghcr-pull` Secret 이 `kyverno` NS 에 존재 — GHCR 패키지가 private 이라 서명 bundle 조회에 registry 자격증명 필요 (values `existingImagePullSecrets`)

## 2. 설치

ArgoCD Application 2개가 담당 (`../argocd/apps/kyverno.yaml` — 차트, `kyverno-policies.yaml` — 정책):

1. `policies/verify-image-signature.yaml` 의 `<cosign.pub-content>` 를 실제 `cosign.pub` 내용(BEGIN/END PUBLIC KEY 블록 전체)으로 교체
2. `ghcr-pull` Secret 을 kyverno NS 로 복사 (서명 bundle 조회용):

```bash
kubectl create secret generic ghcr-pull -n kyverno \
  --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson="$(kubectl get secret ghcr-pull -n auth -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)"
```

3. push → root app 이 새 Application 2개 발견 → wave 순서(kyverno 6 → kyverno-policies 7)로 sync

```bash
kubectl apply -f ../../infra/namespaces/namespaces.yaml   # kyverno NS 선행
argocd app sync kyverno
argocd app sync kyverno-policies
```

## 3. 검증

```bash
kubectl get pods -n kyverno                    # admission + reports controller Running
kubectl get clusterpolicy                      # verify-svc-image-signature Ready=True

# 정책은 background: false — admission 시점에만 평가됨. 재admission 을 유발해 확인:
kubectl -n auth rollout restart deploy auth    # core/batch 도 동일 (verify-images: "true" 라벨 NS 전부 대상)
kubectl get policyreport -n auth               # PASS 카운트 (서명 검증 통과)
kubectl describe policyreport -n auth | grep -B2 -A6 verify-svc-image-signature
```

## 4. 결정

- **Audit 모드 시작** — Enforce 는 서명 없는 이미지를 admission 에서 거부. Audit 리포트 검증 → Enforce 전환 순서.
- **스코프는 `namespaceSelector`(라벨 `verify-images: "true"`) + `ghcr.io/ggingggang/svc-*` 와일드카드** — `jenkins-shared-library`의 `ci()`가 `services.yaml` `defaults.sign: true`로 전 서비스 서명을 이미 깔고 시작해서(신규 서비스도 명시적으로 `sign: false`를 안 주면 자동 서명), 정책 스코프도 정적 나열 대신 라벨 멤버십으로 따라가게 함. 신규 서비스 온보딩 시 이 정책 파일은 무수정 — `namespaces.yaml`에 `verify-images: "true"` 라벨만 추가.
- **`mutateDigest`/`verifyDigest`: false** — Audit 은 관찰 전용이라 mutation 불가 (kyverno 정책 검증 웹훅이 `mutateDigest=false` 강제). 배포 이미지가 태그(git SHA) 참조라 `verifyDigest` 도 함께 off — 켜두면 서명이 정상이어도 "digest 미참조"로 FAIL 이 찍혀 리포트가 오염됨. **Enforce 전환 시 둘 다 기본(true)으로 되돌려** admission 단계 digest 핀까지 확보.
- **기본(Cosign) 검증 타입 — `type: SigstoreBundle` 미사용** — Kyverno 1.18 은 SigstoreBundle 에서 raw 공개키(`keys.publicKeys`)를 **조용히 무시**해 검증 불가 (kyverno#16267·#14233, 수정 PR #16270 진행 중 — tlog 유무 불문 "no matching signatures found" 실측). 서명을 cosign v2 레거시 포맷으로 맞추고 성숙한 기본 경로를 사용. bundle 의 key 지원이 릴리스되면 v3/bundle 복귀 검토.
- **tlog 미사용 · `rekor.ignoreTlog: true`** — 서명이 `--tlog-upload=false`(자체완결, 공개 Rekor 미의존)라 검증도 tlog 조회를 끔. 이 설정 없으면 Rekor 조회 실패로 검증이 깨짐.
- **`imageRegistryCredentials.secrets: [ghcr-pull]` (rule 레벨)** — private GHCR 의 서명 bundle 조회는 rule 레벨 자격증명만 유효(실측). 차트 전역 `existingImagePullSecrets`(`--imagePullSecrets` 인자)는 파싱은 되지만 SigstoreBundle fetch 경로에 적용되지 않았음 — values 쪽 설정은 정리 대상.
- **GHCR private 유지 + `existingImagePullSecrets: [ghcr-pull]`** — kyverno 는 서명 bundle 을 자체 자격증명으로 조회 (파드의 imagePullSecrets 는 kubelet 용 — 검증 fetch 에 미적용). 차트 최상위 `existingImagePullSecrets` 가 검증용 registry client 에 연결됨. 트레이드오프는 주의 사항 참조.
- **background/cleanup controller off** — mutate-existing/generate/cleanup 정책 미사용. 24GB 예산에서 admission + reports 만 상주.
- **admission replicas 1** — HA 보다 RAM 우선 (다른 플랫폼 컴포넌트와 동일 기조).

## 5. 주의 사항

- **Enforce 전환 전 필수 순서**: `verify-images: "true"` 라벨이 붙은 전 NS(auth/core/batch)가 서명된 digest 로 재배포됐는지 확인 → 그 다음에만 `failureAction: Enforce`. 미서명 이미지가 도는 상태에서 Enforce 켜면 재시작/재스케줄 때 파드 생성이 거부됨.
- webhook 은 정책 match 범위(`verify-images: "true"` 라벨 NS 의 Pod)로 자동 스코프됨 — kyverno 다운 시 영향도 그 범위 안. 라벨 붙은 NS 가 늘수록 kyverno 가용성이 클러스터 admission 에 직결됨.
- 키 로테이션 시 정책 `publicKeys` 도 함께 교체 — 구 키로 서명된 이미지는 새 키로 검증 실패.
- **`ghcr-pull` 토큰 만료 = 검증 실패.** Audit 에선 FAIL 리포트로 그치지만 **Enforce 전환 후엔 auth NS 파드 admission 거부로 승격.** 토큰 로테이션 시 kyverno NS 사본도 함께 갱신 — 시크릿 중앙화(OpenBao) 이관 시 단일 소스로 일원화 대상.
