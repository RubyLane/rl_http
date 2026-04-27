project('rl_http',
  version:            '1.25',
  meson_version:      '>=1.3.0',
)
# Pure-Tcl module: rl_http is a single .tcl file distributed as a Tcl
# Module (.tm). No compiler needed. Meson's implicit 'c' language
# default is unused.

tcl_dep        = dependency('tcl')
tclver_full    = tcl_dep.version()
tclver_parts   = tclver_full.split('.')
tclver_major   = tclver_parts[0]
tclver_minor   = tclver_parts[1].split('a')[0].split('b')[0].split('rc')[0]
tm_install_dir = tcl_dep.get_variable('libdir') / 'tcl' + tclver_major / 'site-tcl'

master_tm_name = meson.project_name() + '-' + meson.project_version() + '.tm'

rl_http_tm = configure_file(
  input:          'rl_http.tcl',
  output:         master_tm_name,
  copy:           true,
  install:        not meson.is_subproject(),
  install_dir:    tm_install_dir,
  install_tag:    'runtime',
)

# pkg-config file with `tcl_tm_path` variable. See chantricks for the
# layout rationale.
pc_conf = configuration_data()
pc_conf.set('PACKAGE_NAME',     meson.project_name())
pc_conf.set('PACKAGE_VERSION',  meson.project_version())
pc_conf.set('TCL_MAJOR',        tclver_major)

configure_file(
  input:          meson.project_name() + '.pc.in',
  output:         meson.project_name() + '.pc',
  configuration:  pc_conf,
  install:        not meson.is_subproject(),
  install_dir:    tcl_dep.get_variable('libdir') / 'pkgconfig',
)

rl_http_dep = declare_dependency(
  variables: {
    'tcl_tm_path': meson.current_build_dir(),
    'version':     meson.project_version(),
  },
)
meson.override_dependency(meson.project_name(), rl_http_dep)

# Devenv so `meson devenv -C <builddir> tclsh` picks up this package
# without having to install it. .tm modules don't appear on auto_path
# (which is what tclsh feeds from TCLLIBPATH) — Tcl scans
# tcl::tm::path instead, populated from the version-specific env var
# TCL<major>_<minor>_TM_PATH. So that's the env var to set, not
# TCLLIBPATH.
tm_env_name = 'TCL' + tclver_parts[0] + '_' + tclver_minor + '_TM_PATH'
devenv = environment()
devenv.prepend(tm_env_name, meson.current_build_dir(), separator: ':')
meson.add_devenv(devenv)

if not meson.is_subproject()
  tclsh = find_program(
    tcl_dep.get_variable('exec_prefix') / 'bin/tclsh' + tclver_parts[0] + '.' + tclver_minor,
    tcl_dep.get_variable('exec_prefix') / 'bin/tclsh',
    'tclsh',
    required: false,
  )
  if tclsh.found()
    # `-load` injects a `package require` so the test interp picks up
    # the just-built .tm file, and tcltest's loadTestedCommands sees
    # the right version (tcltest's auto-discovery would otherwise pull
    # an older system-installed copy if one's around).
    test('tcltest', tclsh,
      args: [
        meson.project_source_root() / 'tests/all.tcl',
        '-load',
        'package require ' + meson.project_name() + ' ' + meson.project_version(),
      ],
      env:      {tm_env_name: meson.current_build_dir()},
      verbose:  true,
      timeout:  120,
    )
  endif
endif

# vim: foldmethod=marker foldmarker=<<<,>>> shiftwidth=2 expandtab
