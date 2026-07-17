# kyverno

정책 엔진. 현재 용도: **이미지 서명 admission 검증** — CI(cosign)가 서명한 이미지만 통과시키는 게이트. Trivy(스캔) → cosign(서명) → Kyverno(검증) 공급망 체인의 마지막 조각.

## 1. 전제 조건

- cosign 서명 체계 가동 — svc 레포 CI 의 `cosignSign` 스텝이 GHCR 에 Sigstore bundle 서명 부착 ([jenkins-shared-library](https://github.com/GGingGGang/jenkins-shared-library) README 참조)
- 서명 검증용 공개키 `cosign.pub` 보유 (키페어 생성 시 산출물 — 공개키라 git 커밋 안전)
- ArgoCD 플랫폼 app-of-apps 가동 (`../argocd/`)
- `kyverno` NS + PSA 라벨 (`../../infra/namespaces/`)

## 2. 설치

ArgoCD Application 2개가 담당 (`../argocd/apps/kyverno.yaml` — 차트, `kyverno-policies.yaml` — 정책):

1. `policies/verify-image-signature.yaml` 의 `<cosign.pub-content>` 를 실제 `cosign.pub` 내용(BEGIN/END PUBLIC KEY 블록 전체)으로 교체
2. push → root app 이 새 Application 2개 발견 → wave 순서(kyverno 6 → kyverno-policies 7)로 sync

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
kubectl -n auth rollout restart deploy auth
kubectl get policyreport -n auth               # PASS 카운트 (서명 검증 통과)
kubectl describe policyreport -n auth | grep -B2 -A6 verify-svc-auth
```

## 4. 결정

- **Audit 모드 시작** — Enforce 는 서명 없는 이미지를 admission 에서 거부. 현재 서명하는 서비스가 svc-auth 뿐이라 Enforce 로 시작하면 core/batch 가 재시작 시점에 전부 막힘. Audit 리포트 검증 → 전 svc 에 Sign 스테이지 확산 → Enforce 전환 순서.
- **스코프 `auth` NS + `ghcr.io/ggingggang/svc-auth*` 한정** — 위와 동일 이유. 확산 시 `namespaces`/`imageReferences` 확장.
- **`mutateDigest`/`verifyDigest`: false** — Audit 은 관찰 전용이라 mutation 불가 (kyverno 정책 검증 웹훅이 `mutateDigest=false` 강제). 배포 이미지가 태그(git SHA) 참조라 `verifyDigest` 도 함께 off — 켜두면 서명이 정상이어도 "digest 미참조"로 FAIL 이 찍혀 리포트가 오염됨. **Enforce 전환 시 둘 다 기본(true)으로 되돌려** admission 단계 digest 핀까지 확보.
- **`type: SigstoreBundle`** — cosign v3 는 서명을 레거시 `.sig` 태그가 아닌 Sigstore bundle(OCI referrer)로 부착. 레거시 방식으로는 서명을 못 찾음.
- **`rekor.ignoreTlog: true`** — 서명이 투명성 로그 없이 생성됨(자체완결 설계, 공개 Rekor 미사용). 이 설정 없으면 Rekor 조회 실패로 검증이 깨짐.
- **background/cleanup controller off** — mutate-existing/generate/cleanup 정책 미사용. 24GB 예산에서 admission + reports 만 상주.
- **admission replicas 1** — HA 보다 RAM 우선 (다른 플랫폼 컴포넌트와 동일 기조).

## 5. 주의 사항

- **Enforce 전환 전 필수 순서**: core/batch Jenkinsfile 에 `cosignSign` 스테이지 추가 → 전 서비스 재빌드(서명된 digest 로 교체) → 그 다음에만 `failureAction: Enforce`. 미서명 이미지가 도는 상태에서 Enforce 켜면 재시작/재스케줄 때 파드 생성이 거부됨.
- webhook 은 정책 match 범위(`auth` NS Pod)로 자동 스코프됨 — kyverno 다운 시 영향도 그 범위 안. NS 를 확장할수록 kyverno 가용성이 클러스터 admission 에 직결됨.
- 키 로테이션 시 정책 `publicKeys` 도 함께 교체 — 구 키로 서명된 이미지는 새 키로 검증 실패.
