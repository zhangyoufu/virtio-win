#!/usr/bin/env bash
set -euo pipefail

log() {
	echo >&2 "$*"
}
export -f log

debug_log() {
	if [ -n "${DEBUG_LOG-}" ]; then
		log "$*"
	fi
}
export -f debug_log

retry() {
	local RETRIES=$1
	shift
	local EXIT_CODE
	local COUNT=0
	until "$@"; do
		EXIT_CODE=$?
		if [ ${COUNT} -lt ${RETRIES} ]; then
			WAIT=$((2 ** COUNT))
			COUNT=$((COUNT + 1))
			log "exit code ${EXIT_CODE}, retry ${COUNT}/${RETRIES} in ${WAIT} seconds..."
			sleep "${WAIT}"
		else
			log "exit code ${EXIT_CODE}, give up"
			return "${EXIT_CODE}"
		fi
	done
	return 0
}
export -f retry

rhsm_request() {
	local URI=$1
	shift
	debug_log "rhsm_request ${URI} $@"
	retry 3 curl -fsS --max-time 5 "https://api.access.redhat.com/management/v1${URI}" -H "Authorization: Bearer ${ACCESS_TOKEN}" "$@" || {
		local EXIT_CODE=$?
		log "curl exit code ${EXIT_CODE}"
		return "${EXIT_CODE}"
	}
}

rhsm_list() {
	local URI=$1
	local OFFSET=0
	local BODY
	local LIMIT
	local COUNT
	shift
	while :; do
		BODY=$(rhsm_request "${URI}" --url-query "offset=${OFFSET}" "$@")
		LIMIT=$(jq -r .pagination.limit <<<"${BODY}")
		COUNT=$(jq -r .pagination.count <<<"${BODY}")
		if [ "${COUNT}" -eq 0 ]; then
			break
		fi
		jq -c .body[] <<<"${BODY}"
		if [ "${COUNT}" -lt "${LIMIT}" ]; then
			break
		fi
		OFFSET=$((OFFSET + COUNT))
	done
}

get_subscription_content_sets() {
	local SUBSCRIPTION=$1

	local SUBSCRIPTION_NUMBER
	local SUBSCRIPTION_NAME
	SUBSCRIPTION_NUMBER=$(jq -r .subscriptionNumber <<<"${SUBSCRIPTION}")
	SUBSCRIPTION_NAME=$(jq -r .subscriptionName <<<"${SUBSCRIPTION}")
	if [ -n "${GITHUB_ACTIONS-}" ]; then
		log "::add-mask::${SUBSCRIPTION_NUMBER}"
	fi

	log "## ${SUBSCRIPTION_NAME}"
	local SUBSCRIPTION_CSETS=$(rhsm_list "/subscriptions/${SUBSCRIPTION_NUMBER}/contentSets" | jq -r '.label | select(test("^rhel-[567]-.*-supplementary-rpms$|^rhel-8-for-x86_64-supplementary.*-rpms$|^rhel-.*-for-x86_64-appstream.*-rpms$") and (test("-for-system-z-|-hpc-node-|-debug-rpms$|-source-rpms$") | not))')
	if [ -n "${SUBSCRIPTION_CSETS}" ]; then
		log "${SUBSCRIPTION_CSETS}"
		echo "${SUBSCRIPTION_CSETS}"
	fi
}

# Note:
# - package name are limited to [-._+0-9A-Za-z]
# - packages are sorted by name in ascending order
find_package_in_content_set() {
	local CSET=$1
	local ARCH=x86_64
	local PKG_NAME=virtio-win

	local PAGE_SIZE=100
	local -a PAGE_PKGS
	fetch_page() {
		local OFFSET=$((PAGE_CUR * PAGE_SIZE))
		coproc { rhsm_request "/packages/cset/${CSET}/arch/${ARCH}" --url-query limit=${PAGE_SIZE} --url-query "offset=${OFFSET}" | jq -c '.body[]'; }
		readarray -t PAGE_PKGS <&"${COPROC[0]}"
		wait -f "$!"
	}

	if [ -n "${GITHUB_ACTIONS-}" ] && [ -n "${DEBUG_LOG-}" ]; then
		log "::group::${CSET}"
	else
		log "## ${CSET}"
	fi

	local PAGE_FIRST_PKG_NAME
	local PAGE_LAST_PKG_NAME

	# phase 1: exponential search to find lower/upper closed bound for the starting page
	local PAGE_LO=0
	local PAGE_HI
	local PAGE_CUR=0
	local PAGE_STRIDE=1
	while :; do
		debug_log "progress: ${PAGE_CUR}"
		fetch_page

		if [ ${#PAGE_PKGS[@]} -eq 0 ]; then
			# overshoot
			PAGE_HI=$((PAGE_CUR - 1))
			break
		fi

		PAGE_FIRST_PKG_NAME=$(jq -r .name <<<"${PAGE_PKGS[0]}")
		debug_log "first: ${PAGE_FIRST_PKG_NAME}"
		if [ "${PAGE_FIRST_PKG_NAME}" \> "${PKG_NAME}" ]; then
			PAGE_HI=$((PAGE_CUR - 1))
			break
		fi
		if [ "${PAGE_FIRST_PKG_NAME}" = "${PKG_NAME}" ]; then
			PAGE_HI=${PAGE_CUR}
			break
		fi

		PAGE_LAST_PKG_NAME=$(jq -r .name <<<"${PAGE_PKGS[-1]}")
		debug_log "last: ${PAGE_LAST_PKG_NAME}"
		if [ "${PAGE_LAST_PKG_NAME}" \< "${PKG_NAME}" ]; then
			PAGE_LO=$((PAGE_CUR + 1))
		else
			PAGE_LO=${PAGE_CUR}
			PAGE_HI=${PAGE_CUR}
			break
		fi

		if [ ${#PAGE_PKGS[@]} -lt ${PAGE_SIZE} ]; then
			# last page
			PAGE_HI=${PAGE_CUR}
			break
		fi

		PAGE_CUR=$((PAGE_CUR + PAGE_STRIDE))
		PAGE_STRIDE=$((PAGE_STRIDE * 2))
	done

	# phase 2: binary search to find exact starting page
	while [ ${PAGE_LO} -lt ${PAGE_HI} ]; do
		PAGE_CUR=$(((PAGE_LO + PAGE_HI) / 2))
		debug_log "progress: ${PAGE_LO}/${PAGE_CUR}/${PAGE_HI}"
		fetch_page

		if [ ${#PAGE_PKGS[@]} -eq 0 ]; then
			# overshoot
			PAGE_HI=$((PAGE_CUR - 1))
			continue
		fi

		PAGE_FIRST_PKG_NAME=$(jq -r .name <<<"${PAGE_PKGS[0]}")
		debug_log "first: ${PAGE_FIRST_PKG_NAME}"
		if [ "${PAGE_FIRST_PKG_NAME}" \> "${PKG_NAME}" ]; then
			PAGE_HI=$((PAGE_CUR - 1))
			continue
		fi
		if [ "${PAGE_FIRST_PKG_NAME}" = "${PKG_NAME}" ]; then
			if [ ${PAGE_LO} -eq ${PAGE_CUR} ]; then
				PAGE_HI=${PAGE_CUR}
				break
			fi
			PAGE_HI=${PAGE_CUR} # guaranteed to trim down the range
			continue
		fi

		PAGE_LAST_PKG_NAME=$(jq -r .name <<<"${PAGE_PKGS[-1]}")
		debug_log "last: ${PAGE_LAST_PKG_NAME}"
		if [ "${PAGE_LAST_PKG_NAME}" \< "${PKG_NAME}" ]; then
			PAGE_LO=$((PAGE_CUR + 1))
			continue
		fi

		PAGE_LO=${PAGE_CUR}
		PAGE_HI=${PAGE_CUR}
		break
	done

	# phase 3: output matching packages
	local PKG_COUNT=0
	if [ ${PAGE_LO} -le ${PAGE_HI} ]; then
		if [ ${PAGE_CUR} -ne ${PAGE_LO} ]; then
			PAGE_CUR=${PAGE_LO}
			debug_log "progress: ${PAGE_CUR}"
			fetch_page
		fi

		local PAGE_PKG_IDX
		local PAGE_PKG_NAME=''
		while :; do
			for ((PAGE_PKG_IDX = 0; PAGE_PKG_IDX < ${#PAGE_PKGS[@]}; PAGE_PKG_IDX++)); do
				PAGE_PKG_NAME=$(jq -r .name <<<"${PAGE_PKGS[$PAGE_PKG_IDX]}")
				if [ "${PAGE_PKG_NAME}" = "${PKG_NAME}" ]; then
					jq -r .checksum <<<"${PAGE_PKGS[$PAGE_PKG_IDX]}"
					PKG_COUNT=$((PKG_COUNT + 1))
					continue
				fi
				if [ "${PAGE_PKG_NAME}" \> "${PKG_NAME}" ]; then
					break
				fi
			done

			# no more match
			if [ "${PAGE_PKG_NAME}" \> "${PKG_NAME}" ]; then
				break
			fi

			# last page
			if [ ${#PAGE_PKGS[@]} -lt ${PAGE_SIZE} ]; then
				break
			fi

			PAGE_CUR=$((PAGE_CUR + 1))
			debug_log "progress: ${PAGE_CUR}"
			fetch_page
		done
	fi

	if [ -n "${GITHUB_ACTIONS-}" ] && [ -n "${DEBUG_LOG-}" ]; then
		log '::endgroup::'
	fi
	log "found ${PKG_COUNT} packages"
}

process_package() {
	local PKG_CHECKSUM=$1

	log "## ${PKG_CHECKSUM}"

	local GIT_TAG=${PKG_CHECKSUM}
	local RELEASE_PUBLISH_TIME=$(awk -v k="${GIT_TAG}" '$1 == k {print $2}' "known_github_release")
	if [ -n "${RELEASE_PUBLISH_TIME}" ]; then
		debug_log 'found GitHub release'
		if ((EPOCHSECONDS - RELEASE_PUBLISH_TIME > 3 * 24 * 60 * 60)); then
			debug_log 'more than 3 days earlier, ignored'
			return
		fi
		debug_log 'check GitHub release assets'
		local RELEASE_ASSETS_COUNT=$(gh release view "${GIT_TAG}" --json assets --jq '[.assets[] | select(.state == "uploaded")] | length')
		if [ "${RELEASE_ASSETS_COUNT}" -ge 1 ]; then
			debug_log 'has release assets, ignored'
			return
		fi
		log 'GitHub release assets missing, try again'
	fi

	local DIR=$(mktemp -d)
	debug_log "DIR: ${DIR}"
	cleanup() {
		trap - EXIT INT TERM
		rm -rf "${DIR}"
	}
	trap cleanup EXIT INT TERM

	log 'download RPM'
	local RPM_URL=$(rhsm_request "/packages/${PKG_CHECKSUM}/download" | jq -r .body.href)
	debug_log "RPM_URL: ${RPM_URL}"
	local RPM_DOWNLOAD_RESULT=$(curl -f "${RPM_URL}" --remote-name --output-dir "${DIR}" --no-progress-meter -w '{"filename_effective":"%{filename_effective}","time_total":%{time_total},"size_download":%{size_download},"speed_download":%{speed_download}}')
	local RPM_DOWNLOAD_TIME=$(jq -r .time_total <<<"${RPM_DOWNLOAD_RESULT}")
	local RPM_DOWNLOAD_SIZE=$(jq -r .size_download <<<"${RPM_DOWNLOAD_RESULT}")
	local RPM_DOWNLOAD_SPEED=$(jq -r .speed_download <<<"${RPM_DOWNLOAD_RESULT}")
	local RPM_FILEPATH=$(jq -r .filename_effective <<<"${RPM_DOWNLOAD_RESULT}") # full path
	log "downloaded ${RPM_FILEPATH##*/} ($(numfmt --to=iec-i "${RPM_DOWNLOAD_SIZE}")B, $(numfmt --to=iec-i "${RPM_DOWNLOAD_SPEED}")B/s)"
	case ${#PKG_CHECKSUM} in
		64)
			if ! sha256sum --quiet -c <(echo "${PKG_CHECKSUM}  ${RPM_FILEPATH}") >/dev/null; then
				log 'RPM SHA-256 mismatch'
				exit 1
			fi
		;;
		*)
			log 'unexpected package checksum length, unable to check RPM integrity'
			exit 1
		;;
	esac

	log 'query package metadata'
	local PKG_METADATA=$(rhsm_request "/packages/${PKG_CHECKSUM}" | jq -c .body)
	debug_log "PKG_METADATA: ${PKG_METADATA}"
	local PKG_FULL_VERSION=$(jq -r '"\(if .epoch == "0" then "" else .epoch + ":" end)\(.version)-\(.release)"' <<<"${PKG_METADATA}")
	local PKG_DATE=$(jq -r .buildDate <<<"${PKG_METADATA}") # ISO 8601

	log 'extract RPM'
	rpm2cpio "${RPM_FILEPATH}" | cpio -idm --quiet --directory "${DIR}" './usr/share/virtio-win/*.iso' './usr/share/virtio-win/*.vfd'
	find "${DIR}/usr/share/virtio-win/" -type l -delete

	local -
	shopt -s nullglob
	local -a FILES=("${DIR}/usr/share/virtio-win/"*)
	if [ "${#FILES[@]}" -eq 0 ]; then
		log 'file not found'
	fi
	ls -lh "${DIR}/usr/share/virtio-win/" | tail -n +2 >&2

	log 'create git commit and tag'
	local COMMIT=$(GIT_AUTHOR_DATE=${PKG_DATE} GIT_COMMITTER_DATE=${PKG_DATE} git commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 </dev/null)
	debug_log "COMMIT: ${COMMIT}"
	git tag -f "${GIT_TAG}" "${COMMIT}"
	git push --quiet -f origin "refs/tags/${GIT_TAG}"

	if [ -z "${RELEASE_PUBLISH_TIME}" ]; then
		log 'create GitHub release'
		gh release create "${GIT_TAG}" --target "${COMMIT}" --latest=false --title "virtio-win ${PKG_FULL_VERSION}" --notes $'```json\n'"$(jq '{buildDate,buildHost}' <<<"${PKG_METADATA}")"$'\n```' >/dev/null
	fi

	log 'upload GitHub release assets'
	for FILE in "${FILES[@]}"; do
		log "upload ${FILE##*/}"
		retry 2 gh release upload --clobber "${GIT_TAG}" "${FILE}"
	done

	cleanup
}

export PARALLEL='--will-cite --halt soon,fail=2'
export TMPDIR=${TMPDIR-/tmp}

log '# authenticate via Red Hat SSO'
ACCESS_TOKEN=$(curl -fsS --max-time 5 https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token -d grant_type=refresh_token -d client_id=rhsm-api -d "refresh_token=${REDHAT_API_OFFLINE_TOKEN}" | jq -r .access_token)
export ACCESS_TOKEN

log '# get active subscriptions'
SUBSCRIPTION_JSON_LINES=$(rhsm_list /subscriptions | jq -c 'select(.status == "Active")')
if [ -z "${SUBSCRIPTION_JSON_LINES}" ]; then
	log 'no active subscription'
	exit 1
fi

log '# get content sets from subscriptions'
CSET_LINES=$(export -f get_subscription_content_sets rhsm_list rhsm_request; parallel --group bash -c "'"'set -euo pipefail; get_subscription_content_sets "$1"'"'" _ <<<"${SUBSCRIPTION_JSON_LINES}")
if [ -z "${CSET_LINES}" ]; then
	log 'no content set'
	exit 1
fi
declare -A CSETS=()
while read -r CSET; do CSETS[$CSET]=; done <<<"${CSET_LINES}"
log "total: ${#CSETS[@]} content sets"

log '# find packages from content sets'
PKG_LINES=$(export -f find_package_in_content_set rhsm_request; printf '%s\n' "${!CSETS[@]}" | parallel --group --jobs 4 bash -c "'"'set -euo pipefail; find_package_in_content_set "$1"'"'" _)
if [ -z "${PKG_LINES}" ]; then
	log 'no package'
	exit 1
fi
declare -A PKGS=()
while read -r PKG_CHECKSUM; do PKGS[$PKG_CHECKSUM]=; done <<<"${PKG_LINES}"
log "total: ${#PKGS[@]} packages"

log '# get GitHub releases'
gh release list --limit 99999 --json tagName,publishedAt --jq '.[] | "\(.tagName) \(.publishedAt|fromdateiso8601)"' >"known_github_release"

log '# process packages'
(export -f process_package rhsm_request; printf '%s\n' "${!PKGS[@]}" | parallel --retries 1 --group --jobs 16 bash -c "'"'set -euo pipefail; process_package "$1"'"'" _)
