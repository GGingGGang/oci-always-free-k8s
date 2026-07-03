#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./sed-template.sh <ORG> <SVC> [OUTDIR]
#   ./sed-template.sh            # 인자 없으면 대화형 입력
#
# ORG : GitHub owner (go.mod / import 는 대소문자 유지, 이미지 경로는 소문자로 변환)
# SVC : 서비스 짧은 이름 (예: auth) -> 리포는 svc-<SVC>
# OUTDIR : 결과물 위치 (기본 ./_generated)

TPL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ORG="${1:-}"
SVC="${2:-}"
OUTDIR="${3:-$TPL_DIR/_generated}"

if [[ -z "$ORG" ]]; then read -rp "ORG (GitHub owner): " ORG; fi
if [[ -z "$SVC" ]]; then read -rp "SVC (service name, e.g. auth): " SVC; fi

if [[ -z "$ORG" || -z "$SVC" ]]; then
  echo "ORG, SVC 는 비어 있을 수 없음" >&2; exit 1
fi
if [[ ! "$SVC" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "SVC 는 소문자/숫자/하이픈만 (예: auth): '$SVC'" >&2; exit 1
fi

ORGLC="$(printf '%s' "$ORG" | tr '[:upper:]' '[:lower:]')"

BUILD="$OUTDIR/svc-$SVC"
GITOPS="$OUTDIR/gitops-$SVC"
rm -rf "$BUILD" "$GITOPS"
mkdir -p "$BUILD" "$GITOPS"

# 1) build 단위: go-app 루트에서 k8s-gitops/, 스크립트, README 제외하고 복사
(
  cd "$TPL_DIR"
  find . -mindepth 1 -maxdepth 1 \
    ! -name k8s-gitops \
    ! -name 'sed-template.sh' \
    ! -name '_generated' \
    ! -iname 'README*' \
    -exec cp -r {} "$BUILD"/ \;
)

# 2) gitops 단위: manifests/go-app -> manifests/<SVC>, apps/go-app.yaml -> <SVC>.yaml
cp -r "$TPL_DIR/k8s-gitops/." "$GITOPS"/
mv "$GITOPS/manifests/go-app"      "$GITOPS/manifests/$SVC"
mv "$GITOPS/argocd/apps/go-app.yaml" "$GITOPS/argocd/apps/$SVC.yaml"

# 3) 토큰 치환 (ORGLC 를 ORG 보다 먼저)
find "$BUILD" "$GITOPS" -type f -exec sed -i \
  -e "s|__ORGLC__|$ORGLC|g" \
  -e "s|__ORG__|$ORG|g" \
  -e "s|__SVC__|$SVC|g" \
  {} +

# 4) 잔여 토큰 검사 (있으면 실패로 간주)
if grep -rn '__[A-Z]*__' "$BUILD" "$GITOPS" >/dev/null 2>&1; then
  echo "남은 토큰 있음 — 씨앗에 누락된 치환 지점:" >&2
  grep -rn '__[A-Z]*__' "$BUILD" "$GITOPS" >&2
  exit 1
fi

cat <<EOF

생성 완료. 잔여 토큰 0.

  빌드 리포 (-> github.com/$ORG/svc-$SVC 의 루트):
    $BUILD

  gitops 조각 (-> k8s-gitops 리포로 복사):
    $GITOPS/manifests/$SVC/        -> k8s-gitops/manifests/$SVC/
    $GITOPS/argocd/apps/$SVC.yaml  -> k8s-gitops/argocd/apps/$SVC.yaml

다음 (명령만, 직접 실행):
  cd "$BUILD" && go mod tidy        # go.sum 생성
  # git init / remote add / push -> github.com/$ORG/svc-$SVC

손으로 확인 (sed 로 안 되는 배선):
  1) 네임스페이스 '$SVC' 생성 (플랫폼 네임스페이스 매니페스트)
  2) AppProject 'apps' 의 spec.destinations 에 namespace '$SVC' 추가
     -> 빠지면 ArgoCD 가 sync 거부

판정:
  kubectl -n $SVC get deploy $SVC -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
  # -> ghcr.io/$ORGLC/svc-$SVC:<40 SHA> 이면 완주
EOF
