WordPress Benchmark
-------------------

The WordPress Benchmark is a standalone `bash` script that performs a
multi-phase, load-test oriented benchmark against WordPress and WooCommerce.
The script will set up a database and prepare a clean WordPress installation
before performing the benchmark, and can orchestrate its actions on remote hosts
to simulate independent database and web servers.

### Usage

```bash
# clone the repository
$ git clone https://github.com/DeepInfoSci/wordpress-bench.git
$ cd ./wordpress-bench/

# run with defaults for all parameters
$ ./wbench

# ...or, set options as desired
$ ./wbench --help
wordpress benchmark version 1.0

Usage: ./wbench [engine] [options]

   Run WordPress Benchmark against specified engine ('deep' or 'innodb').

   Options (provided as '--option=value'):

      --mysqld-server        Address or domain of mysqld server
      --apache-server        Address or domain of apache server
      --siege-server         Address or domain of siege server

      --mysqld-basedir       Directory containing MySQL installation files
      --mysqld-cache-size    Amount of memory mysqld should allocate
      --mysqld-port          Port that mysqld should listen on

      --cache-adjust-size    During benchmark, adjust cache to this amount
      --deepsql-logs         Enable/disable deep log messages

      --siege-max-time       Maximum runtime of a siege
      --siege-min-time       Minimum runtime of a siege
      --siege-recovery-time  Amount of time to sleep after each siege
      --siege-concurrency    Number of concurrent clients siege should simulate

      --scale-factor         Linear scalar applied to products and comments
      --static-products      Number of products to generate
      --static-comments      Number of comments to generate
      --realtime-products    Number of products to generate while under load
      --realtime-comments    Number of comments to generate while under load

      --ssh-user             Username to use for remote connections
      --workspace            Directory to use during benchmark
      --resultsdir           Directory to use when archiving results
      --keep                 Whether or not to keep results of this run
```

__Using Remote Servers__

By default, the script will run all processes on localhost. If configured to use
remote servers, you will be prompted for your ssh credentials. The script then
installs its own key on the remote servers for use during the benchmark. When
the script exits, the key will be removed from each server.

### Requirements

The script will try to identify missing packages before starting the benchmark.
Aside from many standard GNU/Linux utilities, the following programs must be
installed on the appropriate servers: `mysqld`, `php` (with bindings for mysql),
`apache2` (or `httpd`), and `siege`. The script also requires that the user
specified as the `ssh-user` has `ssh` access to the remote hosts, as well as
`sudo` privileges on the apache host (to install configs and reload the
service).

### Phases

The benchmark runs five phases:

 1. Base WordPress installation

    The script will create a database, then download and install WordPress. A
    number of users and posts are generated before starting a short siege
    against the homepage to establish baseline performance.
    
 2. WooCommerce with static data

    The sript then installs WooCommerce and generates a number of products and
    comments based on the provided parameters. A siege is run against a list of
    urls that includs the site homepage, the login and "my account" pages,
    product and category pages, cart and checkout pages, and all generated
    individual product pages. This simulates a standard read-heavy workload.

 3. Realtime data and siege

    Here the script generates products and comments in parallel with a siege.
    This simulates a heavy read workload with some concurrent writes.

 4. Additional common plugins

    Next the script will install and activate a handful of common plugins, then
    run another siege against the list of urls described above.

 5. Dynamic Resource Awareness

    When available, the allowed cache size is increased before performing a
    final siege. This demonstrates a database engine's ability to respond to
    dynamically changing resources (ie, scaling a virtual/provisioned machine).

### LICENSE

  The WordPress Benchmark is MIT licensed. See LICENSE for details.
