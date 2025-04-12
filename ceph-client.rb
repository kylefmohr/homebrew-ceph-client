class CephClient < Formula
  desc "Ceph client tools and libraries"
  homepage "https://ceph.com"
  url "https://download.ceph.com/tarballs/ceph-17.2.5.tar.gz"
  sha256 "362269c147913af874b2249a46846b0e6f82d2ceb50af46222b6ddec9991b29a"
  revision 2 # Increment revision due to build change

  bottle do
    # You might need to remove the old bottle block or update it after building
    # For now, let's comment it out as it's for the previous build method
    # rebuild 1
    # root_url "https://github.com/mulbc/homebrew-ceph-client/releases/download/quincy-17.2.5-1"
    # sha256 cellar: :any, arm64_ventura: "b6e30275e0c5012874b73130fd0119b7f40f8180f1c6b54e3abb1f8bf8680ed5"
  end

  # depends_on "osxfuse" # Keep commented unless explicitly needed and handled
  # depends_on "boost@1.76" # REMOVED - We will build it from source

  # Build dependencies
  depends_on "cmake" => :build
  depends_on "cython" => :build
  depends_on "leveldb" => :build # Should this be :build? Ceph links against it. Keep as runtime for now.
  depends_on "ninja" => :build
  depends_on "openssl@3" => :build # Use openssl@3 for consistency if available, otherwise openssl
  depends_on "pkg-config" => :build
  depends_on "python@3.11" => :build # Also needed at runtime for bindings
  depends_on "sphinx-doc" => :build

  # Runtime dependencies
  depends_on "leveldb"
  depends_on "nss"
  depends_on "openssl@3" # Use openssl@3 for consistency if available, otherwise openssl
  depends_on "python@3.11"
  depends_on "yasm" # Needed by boost build? Check boost reqs. Usually needed for crypto. Keep for now.

  # Resource for Boost
  resource "boost" do
    url "https://archives.boost.io/release/1.76.0/source/boost_1_76_0.tar.gz"
    sha256 "7bd7ddceec1a1dfdcbdb3e609b60d01739c38390a5f956385a12f3122049f0ca"
  end

  resource "prettytable" do
    url "https://files.pythonhosted.org/packages/cb/7d/7e6bc4bd4abc49e9f4f5c4773bb43d1615e4b476d108d1b527318b9c6521/prettytable-3.2.0.tar.gz"
    sha256 "ae7d96c64100543dc61662b40a28f3b03c0f94a503ed121c6fca2782c5816f81"
  end

  resource "PyYAML" do
    url "https://files.pythonhosted.org/packages/36/2b/61d51a2c4f25ef062ae3f74576b01638bebad5e045f747ff12643df63844/PyYAML-6.0.tar.gz"
    sha256 "68fb519c14306fec9720a2a5b45bc9f0c8d1b9c72adf45c37baedfcd949c35a2"
  end

  resource "wcwidth" do
    url "https://files.pythonhosted.org/packages/89/38/459b727c381504f361832b9e5ace19966de1a235d73cdbdea91c771a1155/wcwidth-0.2.5.tar.gz"
    sha256 "c4d647b99872929fdb7bdcaa4fbe7f01413ed3d98077df798530e5b04f116c83"
  end

  patch :DATA

  def caveats
    <<~EOS
      macFUSE must be installed prior to building this formula if you plan to use
      the FUSE support of CephFS (WITH_CEPHFS=ON). You can either install macFUSE
      from https://osxfuse.github.io or use the following command:

        brew install --cask macfuse

      ---

      The fuse version shipped with macFUSE might be too old to access the
      supplementary group IDs in cephfs.
      If you encounter permission errors, you may need to add this to your
      ceph.conf to avoid errors:

      [client]
      fuse_set_user_groups = false
    EOS
  end


  def install
    # --- Python Setup ---
    python = Formula["python@3.11"]
    python_exe = python.opt_bin/"python3.11"
    pip_exe = python.opt_bin/"pip3.11"
    python_prefix = python.opt_frameworks/"Python.framework/Versions/3.11"
    xy = Language::Python.major_minor_version python_exe

    venv_root = libexec/"vendor"
    py_site_packages = venv_root/"lib/python#{xy}/site-packages"
    ENV.prepend_create_path "PYTHONPATH", py_site_packages
    ENV.prepend_path "PATH", Formula["cython"].opt_libexec/"bin" # Ensure cython is available

    # --- Install Python Resources ONLY ---
    python_resources = resources.select { |r| ["prettytable", "PyYAML", "wcwidth"].include?(r.name) }
    python_resources.each do |r|
      r.stage do
        staged_dir = Pathname.pwd
        source_path = staged_dir
        unless (staged_dir/"setup.py").exist? || (staged_dir/"pyproject.toml").exist?
          subdirs = staged_dir.children.select(&:directory?)
          if subdirs.length == 1
            source_path = subdirs.first
            ohai "Python Resource #{r.name}: setup file not in root, found source dir #{source_path.basename}"
          else
            raise "Could not find setup.py/pyproject.toml in #{staged_dir} or a unique subdirectory for Python resource #{r.name}"
          end
        end
        ohai "Installing Python resource #{r.name} from #{source_path} into #{py_site_packages}"
        system pip_exe, "install", source_path.to_s, \
               "--target=#{py_site_packages}", \
               "--no-deps", \
               "--no-build-isolation"
      end
    end

    # --- Boost Build (Separate from Python resources) ---
    boost_prefix = libexec/"boost"
    boost_lib_path = boost_prefix/"lib" # Define early for RPATH use
    resource("boost").stage do
      py_include = "#{python_prefix}/include/python#{xy}"
      py_lib = "#{python_prefix}/lib"

      (buildpath/"user-config.jam").write <<~EOS
        using python : #{xy}
                   : #{python_exe}
                   : #{py_include}
                   : #{py_lib} ;
      EOS

      system "./bootstrap.sh", "--prefix=#{boost_prefix}", "--with-python=#{python_exe}"
      system "./b2", "install",
             "-j#{ENV.make_jobs}",
             "--prefix=#{boost_prefix}",
             "--user-config=#{buildpath}/user-config.jam",
             "link=shared",
             "variant=release",
             "threading=multi",
             "python=#{xy}"
    end

    # --- Ceph Build ---
    ENV.prepend_path "PKG_CONFIG_PATH", Formula["nss"].opt_lib/"pkgconfig"
    ENV.prepend_path "PKG_CONFIG_PATH", Formula["openssl@3"].opt_lib/"pkgconfig"
    ENV.prepend_path "CMAKE_PREFIX_PATH", boost_prefix

    ceph_rpath = [rpath, boost_lib_path].join(":")

    args = %W[
      -DDIAGNOSTICS_COLOR=always
      -DOPENSSL_ROOT_DIR=#{Formula["openssl@3"].opt_prefix}
      -DWITH_BABELTRACE=OFF
      -DWITH_BLUESTORE=OFF
      -DWITH_CCACHE=OFF
      -DWITH_CEPHFS=OFF
      -DWITH_KRBD=OFF
      -DWITH_LIBCEPHFS=ON
      -DWITH_LTTNG=OFF
      -DWITH_LZ4=OFF
      -DWITH_MANPAGE=ON
      -DWITH_MGR=OFF
      -DWITH_MGR_DASHBOARD_FRONTEND=OFF
      -DWITH_PYTHON3=#{xy}
      -DWITH_RADOSGW=OFF
      -DWITH_RDMA=OFF
      -DWITH_SPDK=OFF
      -DWITH_SYSTEM_BOOST=OFF
      -DWITH_SYSTEMD=OFF
      -DWITH_TESTS=OFF
      -DWITH_XFS=OFF
      -DCMAKE_INSTALL_RPATH=#{ceph_rpath}
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    ]

    targets = %w[
      rados
      rbd
      cephfs
      ceph-conf
      ceph-fuse
      manpages
      cython_rados
      cython_rbd
    ]

    mkdir "build" do
      system "cmake", "-G", "Ninja", "..", *args, *std_cmake_args
      system "ninja", *targets

      # --- Installation ---
      %w[
        ceph
        ceph-conf
        ceph-fuse
        rados
        rbd
      ].each { |f| bin.install "bin/#{f}" }

      lib.install Dir["lib/*.dylib"]

      %w[
        ceph-conf
        ceph-fuse
        ceph
        librados-config
        rados
        rbd
      ].each { |f| man8.install "doc/man/#{f}.8" }

      # Install Python bindings using ninja install targets
      system "ninja", "src/pybind/install", "src/include/install"

      # Optional: Verify Python bindings location (useful for debugging)
      expected_py_bindings_path = prefix/"lib/python#{xy}/site-packages"
      if Dir.exist?(expected_py_bindings_path/"rados") && Dir.exist?(expected_py_bindings_path/"rbd")
        ohai "Ceph Python bindings successfully installed to: #{expected_py_bindings_path}"
      else
        opoo "Ceph Python bindings not found in expected location: #{expected_py_bindings_path}"
        opoo "Check CMake output and ninja install steps for pybind."
      end
    end
  end # end install method

# Keep the patch as it seems necessary for Python binding installation paths
__END__
diff --git a/cmake/modules/Distutils.cmake b/cmake/modules/Distutils.cmake
index 9d66ae979a6..eabf22bf174 100644
--- a/cmake/modules/Distutils.cmake
+++ b/cmake/modules/Distutils.cmake
@@ -93,11 +93,9 @@ function(distutils_add_cython_module target name src)
     OUTPUT ${output_dir}/${name}${ext_suffix}
     COMMAND
     env
-    CC="${PY_CC}"
     CFLAGS="${PY_CFLAGS}"
     CPPFLAGS="${PY_CPPFLAGS}"
     CXX="${PY_CXX}"
-    LDSHARED="${PY_LDSHARED}"
     OPT=\"-DNDEBUG -g -fwrapv -O2 -w\"
     LDFLAGS=-L${CMAKE_LIBRARY_OUTPUT_DIRECTORY}
     CYTHON_BUILD_DIR=${CMAKE_CURRENT_BINARY_DIR}
@@ -125,8 +123,6 @@ function(distutils_install_cython_module name)
     set(maybe_verbose --verbose)
   endif()
   install(CODE "
-    set(ENV{CC} \"${PY_CC}\")
-    set(ENV{LDSHARED} \"${PY_LDSHARED}\")
     set(ENV{CPPFLAGS} \"-iquote${CMAKE_SOURCE_DIR}/src/include
                         -D'void0=dead_function\(void\)' \
                         -D'__Pyx_check_single_interpreter\(ARG\)=ARG\#\#0' \
@@ -135,7 +131,7 @@ function(distutils_install_cython_module name)
     set(ENV{CYTHON_BUILD_DIR} \"${CMAKE_CURRENT_BINARY_DIR}\")
     set(ENV{CEPH_LIBDIR} \"${CMAKE_LIBRARY_OUTPUT_DIRECTORY}\")

-    set(options --prefix=${CMAKE_INSTALL_PREFIX})
+    set(options --prefix=${CMAKE_INSTALL_PREFIX} --install-lib=${CMAKE_INSTALL_PREFIX}/lib/python3.11/site-packages)
     if(DEFINED ENV{DESTDIR})
       if(EXISTS /etc/debian_version)
         list(APPEND options --install-layout=deb)
