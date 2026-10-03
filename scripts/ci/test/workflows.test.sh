#!/usr/bin/env bash
# GitHub Actions 워크플로의 구조·안전 규칙 테스트(YAML만 읽는다). 실행: bash scripts/ci/test/workflows.test.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
pass=0 fail=0

# 파이썬이 규칙별로 "RULE<TAB>설명<TAB>ok|FAIL"을 출력한다.
results=$(python3 - "$repo_root/.github/workflows" <<'PY'
import sys, glob, os, re, yaml

d = sys.argv[1]
wf = {os.path.basename(f): yaml.safe_load(open(f)) for f in glob.glob(d + "/*.yml")}

def trig(w):
    return w.get("on") or w.get(True) or {}

out = []
def rule(desc, cond):
    out.append("%s\t%s" % (desc, "ok" if cond else "FAIL"))

# --- 이벤트 호출 워크플로 3종 --------------------------------------------------
callers = {
    "deploy-ai.yml":       ("deploy-ai",       "ai", "42VoiceBridge/42VoiceBridge_AI", "AI_IMAGE_REPOSITORY", "deploy-ai"),
    "deploy-backend.yml":  ("deploy-backend",  "be", "42VoiceBridge/42VoiceBridge_BE", "BE_IMAGE_REPOSITORY", "deploy-be"),
    "deploy-frontend.yml": ("deploy-frontend", "fe", "42VoiceBridge/42VoiceBridge_FE", "FE_IMAGE_REPOSITORY", "deploy-fe"),
}
groups = []
for f, (event, comp, src, var, group) in callers.items():
    w = wf[f]
    t = trig(w)
    rule("%s: repository_dispatch만 받고 타입은 %s 하나" % (f, event),
         list(t.keys()) == ["repository_dispatch"] and t["repository_dispatch"]["types"] == [event])
    job = w["jobs"]["deploy"]
    rule("%s: 공통 재사용 워크플로를 호출" % f, job.get("uses") == "./.github/workflows/deploy-component.yml")
    wi = job["with"]
    rule("%s: 컴포넌트·소스 레포 매핑이 맞음" % f, wi["component"] == comp and wi["source_repository"] == src)
    rule("%s: 이미지 저장소는 Infra 변수 %s에서만" % (f, var), wi["image_repository"] == "${{ vars.%s }}" % var)
    rule("%s: payload는 ref, sha, image만 전달(이미지 경로 조립은 변수로)" % f,
         wi["ref"] == "${{ github.event.client_payload.ref }}" and wi["sha"] == "${{ github.event.client_payload.sha }}")
    c = w["concurrency"]
    rule("%s: 컴포넌트별 concurrency 그룹이고 취소하지 않음" % f, c["group"] == group and c.get("cancel-in-progress") is False)
    rule("%s: 권한은 contents: read뿐" % f, w["permissions"] == {"contents": "read"})
    groups.append(c["group"])
rule("컴포넌트별 concurrency 그룹이 서로 다름(다른 컴포넌트 배포를 막지 않음)", len(set(groups)) == 3)
rule("cd-preflight는 더 이상 repository_dispatch를 받지 않음(BE 이벤트 중복 처리 방지)",
     "repository_dispatch" not in trig(wf["cd-preflight.yml"]))

# --- 공통 재사용 워크플로 ------------------------------------------------------
r = wf["deploy-component.yml"]
steps = r["jobs"]["deploy"]["steps"]
def idx(pred):
    for i, s in enumerate(steps):
        if pred(s): return i
    return -1
runs = lambda frag: (lambda s: frag in s.get("run", ""))
i_val = idx(runs("validate-dispatch.sh"))
i_ver = idx(runs("verify-source-commit.sh"))
i_cred = idx(lambda s: str(s.get("uses", "")).startswith("aws-actions/configure-aws-credentials"))
i_acq = idx(runs("infra-lock.sh acquire deploy"))
i_dep = idx(runs("deploy-component.sh"))
i_rel = idx(runs("infra-lock.sh release deploy"))
rule("순서: 형식 검증 → 출처 확인 → AWS 자격 증명 → 락 획득 → 배포 → 락 해제",
     -1 not in (i_val, i_ver, i_cred, i_acq, i_dep, i_rel) and i_val < i_ver < i_cred < i_acq < i_dep < i_rel)
rel = steps[i_rel] if i_rel >= 0 else {}
rule("락 해제는 항상 실행하되 락을 획득한 경우에만(다른 실행의 락을 지우지 않음)",
     "always()" in rel.get("if", "") and "steps.lock.outcome == 'success'" in rel.get("if", ""))
rule("락 획득 단계에 id: lock", steps[i_acq].get("id") == "lock")
rule("출처 확인에 GITHUB_TOKEN을 환경변수로 전달", steps[i_ver].get("env", {}).get("GITHUB_TOKEN") == "${{ github.token }}")
rule("재사용 워크플로는 workflow_call 전용", list(trig(r).keys()) == ["workflow_call"])

# --- Terraform 워크플로 --------------------------------------------------------
pl, ap = wf["terraform-plan.yml"], wf["terraform-apply.yml"]
rule("plan: 수동 실행(workflow_dispatch)만", list(trig(pl).keys()) == ["workflow_dispatch"])
rule("plan: 레이어 선택지는 3개", trig(pl)["workflow_dispatch"]["inputs"]["layer"]["options"] == ["1_base", "2_storage", "3_application"])
plan_runs = " ".join(s.get("run", "") for s in pl["jobs"]["plan"]["steps"])
rule("plan: apply를 실행하지 않음", "apply" not in plan_runs.replace("terraform-apply", ""))
rule("plan: 결과를 아티팩트로 저장", any(str(s.get("uses", "")).startswith("actions/upload-artifact") for s in pl["jobs"]["plan"]["steps"]))
rule("plan: 필수 입력 변수는 Infra Variables에서 TF_VAR_*로 받음",
     pl["jobs"]["plan"]["env"]["TF_VAR_ssh_allowed_cidr"] == "${{ vars.SSH_ALLOWED_CIDR }}" and pl["jobs"]["plan"]["env"]["TF_VAR_ssh_key_name"] == "${{ vars.SSH_KEY_NAME }}")

rule("apply: 수동 실행(workflow_dispatch)만", list(trig(ap).keys()) == ["workflow_dispatch"])
ain = trig(ap)["workflow_dispatch"]["inputs"]
rule("apply: layer, plan_run_id, allow_destroy 입력", set(ain) == {"layer", "plan_run_id", "allow_destroy"})
rule("apply: allow_destroy 기본값은 false", ain["allow_destroy"]["default"] is False)
aj = ap["jobs"]["apply"]
rule("apply: main 브랜치에서만 실행", aj.get("if") == "github.ref == 'refs/heads/main'")
rule("apply: 자동 승인 옵션을 쓰지 않음", "-auto-approve" not in open(os.path.join(d, "terraform-apply.yml")).read().replace("# ", "#"))
asteps = aj["steps"]
def aidx(frag):
    for i, s in enumerate(asteps):
        if frag in s.get("run", ""): return i
    return -1
i_acq, i_app, i_post, i_rel = aidx("infra-lock.sh acquire apply"), aidx("tf-layer.sh apply"), aidx("post-apply.sh"), aidx("infra-lock.sh release apply")
rule("apply 순서: 락 획득 → 저장된 plan apply → 복원 → 락 해제", -1 not in (i_acq, i_app, i_post, i_rel) and i_acq < i_app < i_post < i_rel)
rule("apply: 락 해제는 항상(획득한 경우에만)", "always()" in asteps[i_rel].get("if", "") and "steps.lock.outcome == 'success'" in asteps[i_rel].get("if", ""))
rule("apply: plan 아티팩트를 plan 실행에서 내려받음", any(str(s.get("uses", "")).startswith("actions/download-artifact") and s["with"].get("run-id") == "${{ inputs.plan_run_id }}" for s in asteps))
rule("apply: 다른 실행의 아티팩트를 읽기 위한 actions: read 권한", ap["permissions"].get("actions") == "read")
rule("apply: 전용 concurrency 그룹", ap["concurrency"]["group"] == "terraform-apply" and ap["concurrency"].get("cancel-in-progress") is False)

# --- 전체 안전 규칙 ------------------------------------------------------------
bad_run = []
unpinned = []
for f, w in wf.items():
    for jn, j in (w.get("jobs") or {}).items():
        for s in j.get("steps", []) or []:
            if "${{" in s.get("run", ""):
                bad_run.append("%s:%s" % (f, jn))
            u = s.get("uses")
            if u and "@" in u and re.search(r"@(main|master|latest)$", u):
                unpinned.append(u)
            if u and not u.startswith("./") and "@" not in u:
                unpinned.append(u)
rule("어떤 워크플로도 run 스크립트에 ${{ }}를 직접 넣지 않음(명령 삽입 방지)", not bad_run)
rule("외부 액션은 모두 버전이 고정됨", not unpinned)
rule("모든 워크플로의 기본 권한은 읽기 전용", all(w.get("permissions", {}).get("contents") == "read" for w in wf.values()))
for r_ in out:
    print(r_)
PY
)

while IFS=$'\t' read -r desc status; do
  [[ -n "$desc" ]] || continue
  if [[ "$status" == ok ]]; then pass=$((pass+1)); echo "  ok   - $desc"; else fail=$((fail+1)); echo "  FAIL - $desc"; fi
done <<<"$results"

echo
echo "통과 $pass, 실패 $fail"
[[ "$pass" -gt 0 && "$fail" -eq 0 ]]
