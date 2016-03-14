#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
#set -o xtrace

## global parameters #######################################

readonly WORKSPACE="${WORKSPACE:-/tmp/wordpress-bench}"

readonly REMOTE_USER="${REMOTE_USER:-${USER}}"

readonly MYSQL_SERVER="${MYSQL_SERVER:-localhost}"
readonly HTTPD_SERVER="${HTTPD_SERVER:-localhost}"
readonly SIEGE_SERVER="${SIEGE_SERVER:-localhost}"

readonly SIEGE_TIME="${SIEGE_TIME:-30M}"
readonly SIEGE_USERS="${SIEGE_USERS:-50}"

readonly STATIC_PRODUCT_COUNT="${STATIC_PRODUCT_COUNT:-100}"
readonly STATIC_COMMENT_COUNT="${STATIC_COMMENT_COUNT:-1000}"

readonly REALTIME_PRODUCT_COUNT="${REALTIME_PRODUCT_COUNT:-100}"
readonly REALTIME_COMMENT_COUNT="${REALTIME_COMMENT_COUNT:-200}"

readonly MYSQL_DIR="${MYSQL_DIR:-/usr}"

## internal vars ###########################################

readonly DISTRO=$(head -n1 /etc/issue | tr 'A-Z' 'a-z' | awk '{print $1}')
case "${DISTRO}" in
	ubuntu)
		readonly HTTPD_BIN_NAME='apache2'
		readonly HTTPD_CONF_DIR='/etc/apache2/sites-enabled'
		;;
	centos)
		readonly HTTPD_BIN_NAME='httpd'
		readonly HTTPD_CONF_DIR='/etc/httpd/conf.d'
		;;
	*)
		fail 'Unsupported distro'
esac

readonly STATIC_PRODUCT_JOBS=10
readonly SIEGE_MIN_TIME="5M"
readonly SIEGE_RECOVERY_TIME="60s"

readonly PATH="${WORKSPACE}:${MYSQL_DIR}/bin:${MYSQL_DIR}/scripts:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

## main ####################################################

function usage () {
	echo "
Usage: $0 <engine>

   Run WordPress Benchmark against engine ('deep' or 'innodb').
   See README for details.
"
	exit
}

function main () {
	local readonly arg="${1:---help}"
	if [[ "${arg}" =~ ^-h|--help$ ]]; then
		usage
	elif [[ "${arg}" == 'call' ]]; then
		local readonly fn="$2"
		"${fn}" "${@:3}"
	else
		local readonly engine="$1"
		init "${engine}"
		bench "${engine}"
		fin
	fi
}

function configuration () {
	local readonly products="${STATIC_PRODUCT_COUNT} / ${REALTIME_PRODUCT_COUNT}"
	local readonly comments="${STATIC_COMMENT_COUNT} / ${REALTIME_COMMENT_COUNT}"
	local readonly siege="${SIEGE_TIME} / ${SIEGE_USERS}"
	log "------------------------------------------------------------"
	log 'Configuration:'
	{
		log "mysql: ${MYSQL_SERVER}\thttpd: ${HTTPD_SERVER}\tsiege: ${SIEGE_SERVER}"
		log "siege: ${siege}\tproducts: ${products}\tcomments: ${comments}"
	} |& column -ts $'\t' | indent -n
	log "------------------------------------------------------------"
	log
}

function init () {
	local readonly engine="$1"
	log

	for dep in "${HTTPD_BIN_NAME}" mysqld siege php; do
		which "${dep}" >/dev/null || fail "Missing dependency: ${dep}"
	done

	configuration

	log 'Prepare workspace on each host'
	on 'mysql' "sudo rm -rf ${WORKSPACE};"
	on 'httpd' "sudo rm -rf ${WORKSPACE};"
	on 'siege' "sudo rm -rf ${WORKSPACE};"

	on 'mysql' "mkdir -p ${WORKSPACE}/${engine}/mysql"
	on 'httpd' "mkdir -p ${WORKSPACE}/${engine}/wordpress"
	on 'siege' "mkdir -p ${WORKSPACE}/${engine}"

	log 'Install script on each host'
	for host in "${MYSQL_SERVER}" "${HTTPD_SERVER}" "${SIEGE_SERVER}"; do
		scp "$0" "${REMOTE_USER}@${host}:${WORKSPACE}/main.sh" &>/dev/null
	done

	for host in 'mysql' 'httpd' 'siege'; do
		cat <<-EOF | on "${host}" "cat - > ${WORKSPACE}/env"
		export WORKSPACE="${WORKSPACE}"

		export REMOTE_USER="${REMOTE_USER}"

		export MYSQL_SERVER="${MYSQL_SERVER}"
		export HTTPD_SERVER="${HTTPD_SERVER}"
		export SIEGE_SERVER="${SIEGE_SERVER}"

		export SIEGE_TIME="${SIEGE_TIME}"
		export SIEGE_USERS="${SIEGE_USERS}"

		export STATIC_PRODUCT_COUNT="${STATIC_PRODUCT_COUNT}"
		export STATIC_COMMENT_COUNT="${STATIC_COMMENT_COUNT}"

		export REALTIME_PRODUCT_COUNT="${REALTIME_PRODUCT_COUNT}"
		export REALTIME_COMMENT_COUNT="${REALTIME_COMMENT_COUNT}"

		export MYSQL_DIR="${MYSQL_DIR}"

		export PATH="${WORKSPACE}:${MYSQL_DIR}/bin:${MYSQL_DIR}/scripts:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
		EOF
	done

	on 'mysql' call 'init_mysql_host' "${engine}"
	on 'httpd' call 'init_httpd_host' "${engine}"
	on 'siege' call 'init_siege_host' "${engine}"

	log
}

function init_mysql_host () {
	local readonly engine="$1"

	log "Initialize MySQL host ($(hostname -s))"

	killall --wait --user "${USER}" --quiet -9 mysqld || true

	if [[ "${engine}" == deep ]]; then
		cat > "${WORKSPACE}/deep/mysql.conf" <<-EOF
			[mysqld]
			basedir = ${MYSQL_DIR}
			datadir = ${WORKSPACE}/deep/mysql

			skip-networking = true
			socket = ${WORKSPACE}/deep/mysql.sock

			plugin-load = ha_deep.so

			default-storage-engine = Deep
			default-tmp-storage-engine = Deep
			transaction-isolation = repeatable-read

			deep-log-level-debug = off
			deep-log-level-info = off
			deep-log-level-warn = off
			deep-log-level-error = off

			deep-cache-size = 6G
			deep-mode-durable = off
		EOF
	elif [[ "${engine}" == innodb ]]; then
		cat > "${WORKSPACE}/innodb/mysql.conf" <<-EOF
			[mysqld]
			basedir = ${MYSQL_DIR}
			datadir = ${WORKSPACE}/innodb/mysql

			skip-networking = true
			socket = ${WORKSPACE}/innodb/mysql.sock

			default-storage-engine = InnoDB
			default-tmp-storage-engine = InnoDB
			transaction-isolation = repeatable-read

			innodb-buffer-pool-size = 6G
			innodb-log-file-size = 1G
			innodb-flush-log-at-trx-commit = 2
			query-cache-size = 8M
			max-heap-table-size = 32M
			thread-cache-size = 4
			table-open-cache = 800
		EOF
	fi

	if [[ "${MYSQL_DIR}" == '/usr' ]]; then
		mysql_install_db --no-defaults                  \
			--user="${USER}"                             \
			--socket="${WORKSPACE}/${engine}/mysql.sock" \
			--datadir="${WORKSPACE}/${engine}/mysql"     \
			&>"${WORKSPACE}/${engine}/mysql.install.log"
	else
		mysql_install_db --no-defaults                  \
			--user="${USER}"                             \
			--socket="${WORKSPACE}/${engine}/mysql.sock" \
			--basedir="${MYSQL_DIR}"                     \
			--datadir="${WORKSPACE}/${engine}/mysql"     \
			&>"${WORKSPACE}/${engine}/mysql.install.log"
	fi
}

function init_httpd_host () {
	local readonly engine="$1"

	log "Initialize Apache host ($(hostname -s))"

	curl -sS 'https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar' > "${WORKSPACE}/wp"
	chmod 755 "${WORKSPACE}/wp"

	cat <<-EOF | sudo tee "${HTTPD_CONF_DIR}/wordpress-bench.${engine}.conf" >/dev/null
		Alias /wordpress/${engine} ${WORKSPACE}/${engine}/wordpress
		<Directory "${WORKSPACE}/${engine}/wordpress">
			<IfVersion < 2.4>
			Order allow,deny
			Allow from all
			</IfVersion>
			<IfVersion >= 2.4>
			Require all granted
			</IfVersion>
		</Directory>
	EOF

	sudo service "${HTTPD_BIN_NAME}" restart &>/dev/null
}

function init_siege_host () {
	local readonly engine="$1"

	log "Initialize siege host ($(hostname -s))"

	cat > "${WORKSPACE}/siegerc" <<-EOF
		verbose = false
		quiet = true
		protocol = HTTP/1.1

		time = "${SIEGE_TIME}"
		concurrent = ${SIEGE_USERS}

		benchmark = true
		chunked = true
		delay = 1
		expire-session = true
		failures = 8192
		#internet = true
		#reps = once
		show-logfile = false
		spinner = false
		#timeout = 10
	EOF
}

function bench () {
	local readonly engine="$1"

	log "------------------------------------------------------------"
	log "Starting benchmark for ${engine}"
	log "------------------------------------------------------------"
	log

	log ':: Phase 01: Base Wordpress'
	log

	timer 'start'
	on 'mysql' call 'setup_wordpress_database' "${engine}"
	on 'httpd' call 'install_wordpress_base' "${engine}"
	on 'siege' call 'start_siege' "${engine}" "'phase-01: base wordpress'" "'url:http://${HTTPD_SERVER}/wordpress/${engine}/'"
	on 'mysql' call 'capture_metrics' "${engine}"
	timer 'stop'
	log

	log ':: Phase 02: WooCommerce with static data'
	log

	timer 'start'
	on 'httpd' call 'install_woocommerce_plugins' "${engine}"
	on 'httpd' call 'generate_static_woocommerce_data' "${engine}"
	on 'httpd' call 'generate_siege_url_list' "${engine}" | on 'siege' "cat - > ${WORKSPACE}/${engine}/urls"
	on 'siege' call 'start_siege' "${engine}" "'phase-02: woocommerce static data'" "'file:${WORKSPACE}/${engine}/urls'"
	on 'mysql' call 'capture_metrics' "${engine}"
	timer 'stop'
	log

	log ':: Phase 03: Realtime data under load'
	log

	timer 'start'
	local readonly siege_file=$(mktemp --quiet siege.XXX)
	on 'httpd' "touch ${WORKSPACE}/${engine}/.realtime"
	(
		on 'siege' call 'start_siege' "${engine}" "'phase-03: realtime data + siege'" "'file:${WORKSPACE}/${engine}/urls'"
		on 'httpd' "rm ${WORKSPACE}/${engine}/.realtime"
	) &>"${siege_file}" &
	on 'httpd' call 'generate_realtime_woocommerce_data' "${engine}"
	cat "${siege_file}"
	rm "${siege_file}"
	on 'mysql' call 'capture_metrics' "${engine}"
	timer 'stop'
	log

	log ':: Phase 04: Install common plugins'
	log

	timer 'start'
	on 'httpd' call 'install_additional_plugins' "${engine}"
	on 'siege' call 'start_siege' "${engine}" "'phase-04: common plugins'" "'file:${WORKSPACE}/${engine}/urls'"
	on 'mysql' call 'capture_metrics' "${engine}"
	timer 'stop'
	log

	log ':: Phase 05: Realtime data under load'
	log

	timer 'start'
	local readonly siege_file=$(mktemp --quiet siege.XXX)
	on 'httpd' "touch ${WORKSPACE}/${engine}/.realtime"
	(
		on 'siege' call 'start_siege' "${engine}" "'phase-05: realtime data + siege'" "'file:${WORKSPACE}/${engine}/urls'"
		on 'httpd' "rm ${WORKSPACE}/${engine}/.realtime"
	) &>"${siege_file}" &
	on 'httpd' call 'generate_realtime_woocommerce_data' "${engine}"
	cat "${siege_file}"
	rm "${siege_file}"
	on 'mysql' call 'capture_metrics' "${engine}"
	timer 'stop'
	log

	log "Benchmark complete. See results in ${WORKSPACE}/${engine}"
	log
}

function fin () {
	on 'mysql' "killall --wait --user '${USER}' --quiet mysqld"
	on 'httpd' "sudo rm -f ${HTTPD_CONF_DIR}/wordpress-bench.deep.conf ${HTTPD_CONF_DIR}/wordpress-bench.innodb.conf"
}

## phases ##################################################

function setup_wordpress_database () {
	local readonly engine="$1"

	log 'Start mysqld and create database'
	{
		if [[ -e /usr/lib/mysql/plugin/libtcmalloc_minimal.so ]]; then
			(export LD_PRELOAD=/usr/lib/mysql/plugin/libtcmalloc_minimal.so; mysqld --defaults-file="${WORKSPACE}/${engine}/mysql.conf" &>"${WORKSPACE}/${engine}/mysql.log" &)
		else
			(mysqld --defaults-file="${WORKSPACE}/${engine}/mysql.conf" &>"${WORKSPACE}/${engine}/mysql.log" &)
		fi
		mysqladmin --socket="${WORKSPACE}/${engine}/mysql.sock" --wait=3 --connect-timeout=15 ping

		mysql -uroot --socket="${WORKSPACE}/${engine}/mysql.sock" <<-EOF
		drop database if exists wordpress;

		create database wordpress;

		grant all privileges
			on wordpress.*
			to 'wordpress'@'%'
			identified by 'wordpress';

		grant all privileges
			on wordpress.*
			to 'wordpress'@'localhost'
			identified by 'wordpress';

		flush privileges;
		EOF
	} |& indent
}

function install_wordpress_base () {
	local readonly engine="$1"
	cd "${WORKSPACE}/${engine}/wordpress"

	log 'Download and install Wordpress'
	{
		wp core download

		wp core config          \
			--dbname="wordpress" \
			--dbuser='wordpress' \
			--dbpass='wordpress' \
			--dbhost="${MYSQL_SERVER}:${WORKSPACE}/${engine}/mysql.sock"

		wp core install                                       \
			--url="http://${HTTPD_SERVER}/wordpress/${engine}" \
			--title="${engine}"                                \
			--admin_user="${engine}"                           \
			--admin_password="${engine}"                       \
			--admin_email='admin@example.org'                  \
			--skip-email
	} |& indent

	wp option update --quiet siteurl "http://${HTTPD_SERVER}/wordpress/${engine}"
	wp option update --quiet home "http://${HTTPD_SERVER}/wordpress/${engine}"
	wp option update --quiet posts_per_page 150

	cache_admin_credentials "${engine}"

	log 'Generate users in standard roles'
	{
		timer 'start'
		wp user generate --quiet --count=50    --role='administrator'
		wp user generate --quiet --count=100   --role='editor'
		wp user generate --quiet --count=500   --role='author'
		wp user generate --quiet --count=750   --role='contributor'
		wp user generate --quiet --count=10000 --role='subscriber'
		timer 'stop'
	} |& indent
}

##

function install_woocommerce_plugins () {
	local readonly engine="$1"
	cd "${WORKSPACE}/${engine}/wordpress"

	log 'Install WooCommerce plugins'
	{
		timer 'start'
		wp plugin install --quiet --activate wordpress-importer woocommerce woocommerce-product-generator
		wp theme  install --quiet --activate storefront

		wp option update --quiet woocommerce_calc_taxes yes
		wp option update --quiet woocommerce_tax_display_show incl
		wp option update --quiet woocommerce_tax_display_cart incl
		wp option update --quiet woocommerce_calc_discounts_sequentially yes
		wp option update --quiet woocommerce_calc_shipping yes
		wp option update --quiet woocommerce_ship_to_countries all

		wp option update --quiet woocommerce-product-generator-limit 1000000
		wp option update --quiet woocommerce-product-generator-per-run $(( ${STATIC_PRODUCT_COUNT} / 5 ))
		timer 'stop'
	} |& grep -vP 'Unpacking|Installing|Plugin installed' | indent

	log 'Import WooCommerce dummy data'
	{
		timer 'start'
		wp import --quiet --authors=create "${WORKSPACE}/${engine}/wordpress/wp-content/plugins/woocommerce/dummy-data/dummy-data.xml" &>/dev/null || true
		timer 'stop'
	} |& indent

	local wpnonce=''
	wpnonce=$(curl -sSL --cookie "${WORKSPACE}/${engine}/cookie" \
		"http://${HTTPD_SERVER}/wordpress/${engine}/wp-admin/admin.php?page=wc-setup&step=pages" | grep -oP '(?<=_wpnonce" value=")[^"]+')
	wpnonce=$(curl -sSL --cookie "${WORKSPACE}/${engine}/cookie" --data "save_step=Continue&_wpnonce=${wpnonce}" \
		"http://${HTTPD_SERVER}/wordpress/${engine}/wp-admin/admin.php?page=wc-setup&step=pages" | grep -oP '(?<=_wpnonce" value=")[^"]+')
}

function generate_static_woocommerce_data () {
	local readonly engine="$1" static_product_count="${STATIC_PRODUCT_COUNT}" static_comment_count="${STATIC_COMMENT_COUNT}"
	cd "${WORKSPACE}/${engine}/wordpress"

	log 'Generate users in WooCommerce roles'
	{
		timer 'start'
		wp user generate --quiet --count=100 --role='shop_manager'
		wp user generate --quiet --count=100000 --role='customer'
		timer 'stop'
	} |& indent

	local product_generator_file="${WORKSPACE}/${engine}/wordpress/wp-content/plugins/woocommerce-product-generator/woocommerce-product-generator.php"
	if ! [[ -e "${product_generator_file}.b" ]]; then
		sudo perl -pi.b -e 's/(wp_verify_nonce\([^)]+\))/true \/* $1 *\//g' "${product_generator_file}"
	fi

	log "Generate ${static_product_count} WooCommerce products"
	{
		timer 'start'
		local max_per_client="${static_product_count}"

		local count=0
		local prev=0
		local start_utc=0

		while (( ${count} < ${static_product_count} )); do
			max_per_client=$(( (${static_product_count} - ${count}) / ${STATIC_PRODUCT_JOBS} ))
			if [[ "${max_per_client}" -eq 0 ]]; then
				max_per_client=1
			fi

			start_utc=$(date +%s)
			prev=$(wp db query --quiet 'select count(*) from wp_posts where post_type = "product";' | tail -n1)

			for i in $(seq 1 "${STATIC_PRODUCT_JOBS}"); do
				(curl -sSL --max-time $(( 60*15 )) --cookie "${WORKSPACE}/${engine}/cookie" --data "max=${max_per_client}&submit=Run&action=generate" \
					"http://${HTTPD_SERVER}/wordpress/${engine}/wp-admin/admin.php?page=product-generator" >/dev/null || true) &
			done
			wait

			count=$(wp db query --quiet 'select count(*) from wp_posts where post_type = "product";' | tail -n1)
			log "${count} products ($(bc <<< "scale=1; (${count} / ${static_product_count}) * 100")%) [ $(( ${count} - ${prev} )) in $(minsec $(( $(date +%s) - ${start_utc} ))) ]"
		done
		timer 'stop'
	} |& indent

	log "Generate ${static_comment_count} comments"
	{
		timer 'start'
		wp comment generate --quiet --count="${static_comment_count}"
		wp db query --quiet <<-EOF
			update wp_comments
			set comment_post_ID = floor(rand() * ${static_comment_count})
		EOF
		seq 1 "${static_comment_count}" | xargs wp comment recount --quiet
		timer 'stop'
	} |& indent
}

function generate_siege_url_list () {
	local readonly engine="$1"
	cd "${WORKSPACE}/${engine}/wordpress"

	local readonly my_account_page_id=$(wp db query --quiet 'select id from wp_posts where post_name = "my-account";' | tail -n1)
	local readonly cart_page_id=$(wp db query --quiet 'select id from wp_posts where post_name = "cart";' | tail -n1)
	local readonly checkout_page_id=$(wp db query --quiet 'select id from wp_posts where post_name = "checkout";' | tail -n1)

	for i in {1..10}; do
		echo "http://${HTTPD_SERVER}/wordpress/${engine}/"
		echo "http://${HTTPD_SERVER}/wordpress/${engine}/"
		echo "http://${HTTPD_SERVER}/wordpress/${engine}/"
		echo "http://${HTTPD_SERVER}/wordpress/${engine}/?post_type=product"
		echo "http://${HTTPD_SERVER}/wordpress/${engine}/?post_type=product"
		echo "http://${HTTPD_SERVER}/wordpress/${engine}/?post_type=product"
		echo "http://${HTTPD_SERVER}/wordpress/${engine}/?page_id=${my_account_page_id}"
		echo "http://${HTTPD_SERVER}/wordpress/${engine}/?page_id=${cart_page_id}"
		echo "http://${HTTPD_SERVER}/wordpress/${engine}/?page_id=${cart_page_id}"
		echo "http://${HTTPD_SERVER}/wordpress/${engine}/?page_id=${checkout_page_id}"
	done

	wp db query --quiet <<-EOF | tail -n+3
		select concat('http://${HTTPD_SERVER}/wordpress/${engine}/?product_cat=', slug)
		from wp_terms;
	EOF

	wp db query --quiet <<-EOF | tail -n+3
		select concat('http://${HTTPD_SERVER}/wordpress/${engine}/?product=', post_name)
		from wp_posts
		where
			post_type = 'product';
	EOF

	wp db query --quiet <<-EOF | tail -n+3
		select concat('http://${HTTPD_SERVER}/wordpress/${engine}/?product=', post_name, '#tab-reviews')
		from wp_posts
		where
			post_type = 'product'
	EOF
}

##

function install_additional_plugins () {
	local readonly engine="$1"
	cd "${WORKSPACE}/${engine}/wordpress"

	log 'Install additional Wordpress plugins'
	{
		timer 'start'
		wp plugin install --quiet --activate \
			akismet                           \
			bwp-google-xml-sitemaps           \
			google                            \
			google-analytics-for-wordpress    \
			subscribe-to-comments-reloaded    \
			tinymce-advanced                  \
			w3-total-cache                    \
			wordpress-seo
		timer 'stop'
	} |& grep -vP 'Installing|Unpacking|Plugin installed' | indent
}

function generate_realtime_woocommerce_data () {
	local readonly engine="$1" static_product_count="${STATIC_PRODUCT_COUNT}" realtime_product_count="${REALTIME_PRODUCT_COUNT}" static_comment_count="${STATIC_COMMENT_COUNT}" realtime_comment_count="${REALTIME_COMMENT_COUNT}"
	cd "${WORKSPACE}/${engine}/wordpress"

	log 'Generate realtime data'
	({
		local iters=1
		while [[ -e "${WORKSPACE}/${engine}/.realtime" ]]; do
			log "Generating ${realtime_product_count} products (round ${iters} @ $(date +%H:%M:%S))"
			curl -sSL --max-time $(( 60*15 )) --cookie "${WORKSPACE}/${engine}/cookie" --data "max=${realtime_product_count}&submit=Run&action=generate" \
				"http://${HTTPD_SERVER}/wordpress/${engine}/wp-admin/admin.php?page=product-generator" >/dev/null || true
			((iters+=1))
			sleep 2
		done
	} |& indent) &

	({
		local iters=1
		while [[ -e "${WORKSPACE}/${engine}/.realtime" ]]; do
			log "Generating ${realtime_comment_count} comments (round ${iters} @ $(date +%H:%M:%S))"
			wp comment generate --quiet --count="${realtime_comment_count}" &>/dev/null
			wp db query --quiet <<-EOF
				update wp_comments
				set comment_post_ID = floor(rand() * ${realtime_comment_count})
				where
					comment_id > $(( ${static_comment_count} + (${realtime_comment_count} * ${iters}) ))
			EOF
			seq 1 $(( ${static_comment_count} + (${realtime_comment_count} * ${iters}) )) | xargs wp comment recount --quiet
			((iters+=1))
			sleep 2
		done
	} |& indent) &
	wait
}


## lib #####################################################

function on () {
	local readonly host="$1"
	local readonly hostip=$(
		case "${host}" in
			mysql) echo "${MYSQL_SERVER}" ;;
			httpd) echo "${HTTPD_SERVER}" ;;
			siege) echo "${SIEGE_SERVER}" ;;
		esac)

	if [[ "$2" == 'call' ]]; then
		(ssh -qtt "${REMOTE_USER}@${hostip}" "source ${WORKSPACE}/env; ${WORKSPACE}/main.sh call ${@:3}") 2>/dev/null
	else
		(ssh -qt "${REMOTE_USER}@${hostip}" "[[ -e ${WORKSPACE}/env ]] && source ${WORKSPACE}/env; ${@:2}") 2>/dev/null
	fi
}

function cache_admin_credentials () {
	local readonly engine="$1"

	curl -sS -LD "${WORKSPACE}/${engine}/cookie" -b "${WORKSPACE}/${engine}/cookie.tmp" --data "log=${engine}&pwd=${engine}&testcookie=1&rememberme=forever" \
		"http://${HTTPD_SERVER}/wordpress/${engine}/wp-login.php" >/dev/null
}

function start_siege () {
	local readonly engine="$1"
	local readonly message="$2"
	local readonly against="$3"

	log "Start a siege at $(date +%H:%M:%S)"
	{
		if [[ "${against%%:*}" == url ]]; then
			siege --rc="${WORKSPACE}/siegerc" \
				--mark="${message}" --log="${WORKSPACE}/${engine}/siege.log" --time="${SIEGE_MIN_TIME}" "${against#*:}"
		elif [[ "${against%%:*}" == file ]]; then
			siege --rc="${WORKSPACE}/siegerc" \
				--mark="${message}" --log="${WORKSPACE}/${engine}/siege.log" --reps=once --file=<(shuf "${against#*:}")
		fi
		echo >> "${WORKSPACE}/${engine}/siege.log"
	} |& tail -n+6 | sed -e 's/:\s\+/:\t/g' | column -ts $'\t' | indent

	log "Sleeping ${SIEGE_RECOVERY_TIME} to recover from siege..." |& indent
	sleep "${SIEGE_RECOVERY_TIME}"
}

function capture_metrics () {
	local readonly engine="$1"

	cat <(du -sh "${WORKSPACE}/${engine}/mysql/wordpress/";) \
		>>"${WORKSPACE}/${engine}/du" 2>/dev/null
	
	uptime | sed -e 's/.*load/load/' \
		>>"${WORKSPACE}/${engine}/load"
}

## utility #################################################

function debug () {
	if [[ "${DEBUG}" == 0 ]]; then return; fi
	local readonly func="${FUNCNAME[1]}" line="${BASH_LINENO[0]}"
	printf "debug:$(hostname -s):%03d:  $*\n" "${line}" >&2
}

function log () {
	echo -e "$@"
}

function fail () {
	log "$@"
	log
	exit 1
}

function indent () {
	sed --unbuffered -e 's/\(^\|\r\)/\1   /g'
	if [[ "${1:-}" != '-n' ]]; then
		echo
	fi
}

function timer () {
	local readonly arg="$1"
	: ${__TIMER_ID:=0}
	: ${__TIMER_SECONDS:=}

	if [[ "${arg}" == start ]]; then
		if [[ "${__TIMER_ID}" == 0 ]]; then
			__TIMER_SECONDS="0"
		else
			__TIMER_SECONDS="${__TIMER_SECONDS}::${SECONDS}"
		fi
		((__TIMER_ID+=1))
		SECONDS=0
	elif [[ "${arg}" == stop ]]; then
		log "Completed in $(minsec ${SECONDS})"
		((__TIMER_ID-=1)) || true
		if [[ "${__TIMER_ID}" > 0 ]]; then
			SECONDS=$(( ${SECONDS} + ${__TIMER_SECONDS##*::} ))
		fi
	fi
}

function minsec () {
	local readonly seconds="$1"

	date --utc --date="@${seconds}" +'%H hours %M mins %S seconds' \
		| sed -e 's:01 \(hour\|min\|second\)s:1 \1:g'               \
				-e 's:0\([0-9]\):\1:g'                                \
				-e 's:0 \(hour\|min\|second\)s ::g'
}

trap fin ERR
main "$@"
