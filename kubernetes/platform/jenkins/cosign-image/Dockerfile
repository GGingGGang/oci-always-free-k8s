# cosign v2 (레거시 서명 포맷) + shell — Jenkins 사이드카용.
# 공식 v2 이미지는 distroless(sh/sleep 없음), v3 는 레거시 포맷 서명이 제거됨 → v2 바이너리만 추출해 alpine 에 탑재.
FROM ghcr.io/sigstore/cosign/cosign:v2.4.1 AS cosign
FROM docker.io/alpine:3.21
COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign
ENTRYPOINT ["/usr/local/bin/cosign"]
