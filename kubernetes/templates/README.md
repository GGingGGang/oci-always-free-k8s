# templates

서비스 씨앗 모음. 각 템플릿을 `sed-template.sh` 로 찍어, 빌드 레포와 k8s-gitops 레포로 나눠 폴더째 옮긴다.

| 템플릿 | 설명 |
|--------|------|
| `go-app` | Go (chi) HTTP 서비스 |

## 1. 스탬프

```bash
cd go-app
bash sed-template.sh <ORG> <SVC>
```

`_generated/` 아래 두 폴더가 생긴다.

## 2. 이동 (한눈에)

| `_generated` 산출물 | 옮길 곳 |
|---------------------|---------|
| `svc-<SVC>/` 폴더 전체 | 새 `svc-<SVC>` 레포 루트 |
| `gitops-<SVC>/manifests/<SVC>/` | `k8s-gitops/manifests/<SVC>/` |
| `gitops-<SVC>/argocd/apps/<SVC>.yaml` | `k8s-gitops/argocd/apps/<SVC>.yaml` |

---

## 구동 순서

### 빌드 레포

```bash
cd _generated/svc-<SVC>
go mod tidy
git init
git add -A
git commit -m "bootstrap svc-<SVC>"
git remote add origin https://github.com/<ORG>/svc-<SVC>.git
git branch -M main
git push -u origin main
```

organizationFolder 가 `svc-*` 를 스캔해 파이프라인을 잡는다.

### gitops 레포

```bash
cp -r _generated/gitops-<SVC>/manifests/<SVC>       <k8s-gitops>/manifests/
cp -r _generated/gitops-<SVC>/argocd/apps/<SVC>.yaml <k8s-gitops>/argocd/apps/
```

네임스페이스 배선 — **`sed-template.sh` 산출물에 없음, 아래 2곳은 직접 수동 편집**:

```bash
# 네임스페이스 <SVC> 를 플랫폼 네임스페이스 매니페스트에 추가
# k8s-gitops/argocd/project.yaml 의 spec.destinations 에 namespace <SVC> 직접 추가 (편집)
```

커밋 — `manifests/<SVC>`·`apps/<SVC>.yaml` 은 스탬프 산출물, `project.yaml` 은 위에서 직접 편집한 결과:

```bash
cd <k8s-gitops>
git add manifests/<SVC> argocd/apps/<SVC>.yaml argocd/project.yaml
git commit -m "onboard svc-<SVC>"
git push
```

루트 app-of-apps 가 `argocd/apps/<SVC>.yaml` 을 잡아 배포한다.

### 판정

```bash
kubectl -n <SVC> get deploy <SVC> -o jsonpath='{.spec.template.spec.containers[0].image}'
```

`ghcr.io/<org-lowercase>/svc-<SVC>:<SHA>` 이면 완주.
