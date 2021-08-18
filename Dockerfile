# https://hub.docker.com/_/julia/
ARG BASE_IMAGE=julia:1.6.2
FROM ${BASE_IMAGE}

ENV PKG_NAME "K8sClusterManagers"

# Copy only the essentials from the package such that we can pre-install the package's
# requirements. By only installing the minimum required files we should be able to make
# better use of Docker layer caching. Only when the Project.toml file or the Manifest.toml
# have changed will we be forced to redo these steps.
ENV PKG_PATH /root/.julia/dev/$PKG_NAME
COPY *Project.toml *Manifest.toml $PKG_PATH/
RUN mkdir -p $PKG_PATH/src && echo "module $PKG_NAME end" > $PKG_PATH/src/$PKG_NAME.jl

# Install and build the package dependencies.
RUN julia -e ' \
    using Pkg; \
    Pkg.update(); \
    Pkg.develop(PackageSpec(name=ENV["PKG_NAME"], path=ENV["PKG_PATH"])); \
    '

# Control if pre-compilation is run when new Julia packages are installed.
ARG PKG_PRECOMPILE="true"

# Perform precompilation of dependencies.
RUN if [ "$PKG_PRECOMPILE" = "true" ]; then \
        julia -e 'using Pkg; VERSION >= v"1.7.0-DEV.521" ? Pkg.precompile(strict=true) : Pkg.API.precompile()'; \
    fi

# Build the package.
COPY . $PKG_PATH/
RUN if [ -f $PKG_PATH/deps/build.jl ]; then \
        julia -e 'using Pkg; Pkg.build(ENV["PKG_NAME"])'; \
    fi

# Create a new system image.
ARG CREATE_SYSIMG="false"

ENV PKGS \
    gcc \
    libc-dev
RUN if [ "$CREATE_SYSIMG" = "true" ]; then \
        apt-get update && \
        apt-get -y --no-install-recommends install $PKGS && \
        julia -e 'using Pkg; Pkg.add(PackageSpec(name="PackageCompiler", version="1"))' && \
        julia --trace-compile=$HOME/precompile.jl -e "using $PKG_NAME" && \
        julia -e 'using PackageCompiler; create_sysimage(Symbol(ENV["PKG_NAME"]), replace_default=true)' && \
        apt-get -y --auto-remove purge $PKGS; \
        rm -rf /var/lib/apt/lists/*; \
    elif [ "$PKG_PRECOMPILE" = "true" ]; then \
        julia -e 'using Pkg; VERSION >= v"1.7.0-DEV.521" ? Pkg.precompile(strict=true) : Pkg.API.precompile()'; \
    else \
        echo -n "WARNING: Disabling both PKG_PRECOMPILE and CREATE_SYSIMG will result in " >&2 && \
        echo -n "packages being compiled at runtime which may cause containers to run " >&2 && \
        echo "out of memory." >&2; \
    fi

# Validate that the `julia` can start with the new system image
RUN julia --history-file=no -e 'exit()'

WORKDIR $PKG_PATH

CMD ["julia", "-e", "using Pkg; Pkg.test(ENV[\"PKG_NAME\"])"]
