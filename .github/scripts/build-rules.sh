#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
publish_dir="${PUBLISH_DIR:-${repo_root}/publish}"
tmp_dir="$(mktemp -d)"

trap 'rm -rf "${tmp_dir}"' EXIT

download() {
  local url="$1"
  local destination="$2"

  curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 20 \
    --max-time 120 \
    --output "${destination}" \
    "${url}"
}

generate_geosite_rules() {
  local source_file="$1"
  local domain_set_file="$2"
  local rule_set_file="$3"

  awk \
    -v domain_set_file="${domain_set_file}" \
    -v rule_set_file="${rule_set_file}" \
    '
      BEGIN {
        domain_re = "^[-_[:alnum:]]+([.][-_[:alnum:]]+)*$"
      }

      {
        line = $0
        sub(/\r$/, "", line)
        sub(/[[:space:]].*$/, "", line)
      }

      line == "" || line ~ /^(regexp|keyword):/ {
        next
      }

      line ~ /^full:/ {
        domain = substr(line, 6)
        if (domain ~ domain_re) {
          print domain > domain_set_file
          print "DOMAIN," domain > rule_set_file
        }
        next
      }

      line ~ /^domain:/ {
        domain = substr(line, 8)
        if (domain ~ domain_re) {
          print "." domain > domain_set_file
          print "DOMAIN-SUFFIX," domain > rule_set_file
        }
        next
      }

      line ~ domain_re {
        print "." line > domain_set_file
        print "DOMAIN-SUFFIX," line > rule_set_file
      }
    ' \
    "${source_file}"
}

generate_custom_domain_rules() {
  local source_file="$1"
  local domain_set_file="$2"
  local rule_set_file="$3"

  awk \
    -F ':' \
    -v domain_set_file="${domain_set_file}" \
    -v rule_set_file="${rule_set_file}" \
    '
      BEGIN {
        domain_re = "^[-_[:alnum:]]+([.][-_[:alnum:]]+)*$"
      }

      {
        sub(/\r$/, "", $0)
        sub(/[[:space:]].*$/, "", $2)
      }

      $1 == "full" && $2 ~ domain_re {
        print $2 > domain_set_file
        print "DOMAIN," $2 > rule_set_file
        next
      }

      $1 == "domain" && $2 ~ domain_re {
        print "." $2 > domain_set_file
        print "DOMAIN-SUFFIX," $2 > rule_set_file
      }
    ' \
    "${source_file}"
}

generate_dnsmasq_suffix_rules() {
  local source_file="$1"
  local domain_set_file="$2"
  local rule_set_file="$3"

  perl -ne '/^server=\/([^\/]+)\// && print ".$1\n"' "${source_file}" > "${domain_set_file}"
  perl -ne '/^server=\/([^\/]+)\// && print "DOMAIN-SUFFIX,$1\n"' "${source_file}" > "${rule_set_file}"
}

generate_tld_rules() {
  local source_file="$1"
  local domain_set_file="$2"
  local rule_set_file="$3"

  awk \
    -F ':' \
    -v domain_set_file="${domain_set_file}" \
    -v rule_set_file="${rule_set_file}" \
    '
      BEGIN {
        domain_re = "^[-_[:alnum:]]+([.][-_[:alnum:]]+)*$"
      }

      {
        sub(/\r$/, "", $0)
        sub(/[[:space:]].*$/, "", $2)
      }

      $1 == "domain" && $2 ~ domain_re {
        print "." $2 > domain_set_file
        print "DOMAIN-SUFFIX," $2 > rule_set_file
      }
    ' \
    "${source_file}"
}

generate_cidr_rules() {
  local source_file="$1"
  local domain_set_file="$2"
  local rule_set_file="$3"

  awk '
    /^[0-9]{1,3}([.][0-9]{1,3}){3}\/[0-9]{1,2}$/ {
      print "IP-CIDR," $0
      next
    }

    /:/ && /\/[0-9]+$/ {
      print "IP-CIDR6," $0
    }
  ' "${source_file}" > "${domain_set_file}"

  cp "${domain_set_file}" "${rule_set_file}"
}

assert_file_is_not_empty() {
  local file="$1"

  if [[ ! -s "${file}" ]]; then
    echo "::error file=${file}::Generated file is missing or empty"
    exit 1
  fi
}

normalize_rule_file() {
  local file="$1"
  local normalized_file

  normalized_file="$(mktemp "${tmp_dir}/normalized.XXXXXX")"
  LC_ALL=C sort -u "${file}" > "${normalized_file}"
  mv "${normalized_file}" "${file}"
}

assert_expected_files_are_not_empty() {
  local file

  for file in \
    "${publish_dir}/apple.txt" \
    "${publish_dir}/cncidr.txt" \
    "${publish_dir}/direct.txt" \
    "${publish_dir}/gfw.txt" \
    "${publish_dir}/google.txt" \
    "${publish_dir}/greatfire.txt" \
    "${publish_dir}/icloud.txt" \
    "${publish_dir}/private.txt" \
    "${publish_dir}/proxy.txt" \
    "${publish_dir}/reject.txt" \
    "${publish_dir}/telegramcidr.txt" \
    "${publish_dir}/tld-not-cn.txt" \
    "${publish_dir}/ruleset/apple.txt" \
    "${publish_dir}/ruleset/cncidr.txt" \
    "${publish_dir}/ruleset/direct.txt" \
    "${publish_dir}/ruleset/gfw.txt" \
    "${publish_dir}/ruleset/google.txt" \
    "${publish_dir}/ruleset/greatfire.txt" \
    "${publish_dir}/ruleset/icloud.txt" \
    "${publish_dir}/ruleset/private.txt" \
    "${publish_dir}/ruleset/proxy.txt" \
    "${publish_dir}/ruleset/reject.txt" \
    "${publish_dir}/ruleset/telegramcidr.txt" \
    "${publish_dir}/ruleset/tld-not-cn.txt"; do
    assert_file_is_not_empty "${file}"
  done
}

rm -rf "${publish_dir}"
mkdir -p "${publish_dir}/ruleset"

download "https://raw.githubusercontent.com/Loyalsoldier/domain-list-custom/release/icloud.txt" "${tmp_dir}/custom_icloud.txt"
download "https://raw.githubusercontent.com/Loyalsoldier/domain-list-custom/release/tld-!cn.txt" "${tmp_dir}/custom_tld_not_cn.txt"
download "https://raw.githubusercontent.com/Loyalsoldier/domain-list-custom/release/private.txt" "${tmp_dir}/custom_private.txt"
download "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/reject-list.txt" "${tmp_dir}/loyalsoldier_reject.txt"
download "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt" "${tmp_dir}/loyalsoldier_proxy.txt"
download "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/direct-list.txt" "${tmp_dir}/loyalsoldier_direct.txt"
download "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt" "${tmp_dir}/loyalsoldier_gfw.txt"
download "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/greatfire.txt" "${tmp_dir}/loyalsoldier_greatfire.txt"
download "https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/apple.china.conf" "${tmp_dir}/felixonmars_apple.conf"
download "https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/google.china.conf" "${tmp_dir}/felixonmars_google.conf"
download "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/cn.txt" "${tmp_dir}/cn_cidr.txt"
download "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text/telegram.txt" "${tmp_dir}/telegram_cidr.txt"

generate_custom_domain_rules "${tmp_dir}/custom_icloud.txt" "${publish_dir}/icloud.txt" "${publish_dir}/ruleset/icloud.txt"
generate_dnsmasq_suffix_rules "${tmp_dir}/felixonmars_google.conf" "${publish_dir}/google.txt" "${publish_dir}/ruleset/google.txt"
generate_dnsmasq_suffix_rules "${tmp_dir}/felixonmars_apple.conf" "${publish_dir}/apple.txt" "${publish_dir}/ruleset/apple.txt"
generate_geosite_rules "${tmp_dir}/loyalsoldier_direct.txt" "${publish_dir}/direct.txt" "${publish_dir}/ruleset/direct.txt"
generate_geosite_rules "${tmp_dir}/loyalsoldier_proxy.txt" "${publish_dir}/proxy.txt" "${publish_dir}/ruleset/proxy.txt"
generate_geosite_rules "${tmp_dir}/loyalsoldier_reject.txt" "${publish_dir}/reject.txt" "${publish_dir}/ruleset/reject.txt"
generate_custom_domain_rules "${tmp_dir}/custom_private.txt" "${publish_dir}/private.txt" "${publish_dir}/ruleset/private.txt"
generate_geosite_rules "${tmp_dir}/loyalsoldier_gfw.txt" "${publish_dir}/gfw.txt" "${publish_dir}/ruleset/gfw.txt"
generate_geosite_rules "${tmp_dir}/loyalsoldier_greatfire.txt" "${publish_dir}/greatfire.txt" "${publish_dir}/ruleset/greatfire.txt"
generate_tld_rules "${tmp_dir}/custom_tld_not_cn.txt" "${publish_dir}/tld-not-cn.txt" "${publish_dir}/ruleset/tld-not-cn.txt"
generate_cidr_rules "${tmp_dir}/cn_cidr.txt" "${publish_dir}/cncidr.txt" "${publish_dir}/ruleset/cncidr.txt"
generate_cidr_rules "${tmp_dir}/telegram_cidr.txt" "${publish_dir}/telegramcidr.txt" "${publish_dir}/ruleset/telegramcidr.txt"

assert_expected_files_are_not_empty

while IFS= read -r file; do
  normalize_rule_file "${file}"
done < <(find "${publish_dir}" -type f -name "*.txt" | sort)

find "${publish_dir}" -type f -name "*.txt" | sort
