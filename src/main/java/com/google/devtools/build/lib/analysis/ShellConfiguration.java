// Copyright 2018 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
package com.google.devtools.build.lib.analysis;

import com.google.common.collect.ImmutableList;
import com.google.common.collect.ImmutableMap;
import com.google.devtools.build.lib.analysis.config.BuildOptions;
import com.google.devtools.build.lib.analysis.config.Fragment;
import com.google.devtools.build.lib.analysis.config.FragmentOptions;
import com.google.devtools.build.lib.analysis.config.RequiresOptions;
import com.google.devtools.build.lib.util.OS;
import com.google.devtools.build.lib.util.OptionsUtils.PathFragmentConverter;
import com.google.devtools.build.lib.vfs.PathFragment;
import com.google.devtools.common.options.Option;
import com.google.devtools.common.options.OptionDocumentationCategory;
import com.google.devtools.common.options.OptionEffectTag;
import com.google.devtools.common.options.OptionsClass;
import java.io.File;
import java.util.List;
import java.util.Optional;
import java.util.function.Function;
import javax.annotation.Nullable;

/** A configuration fragment that tells where the shell is. */
@RequiresOptions(options = {ShellConfiguration.Options.class})
public class ShellConfiguration extends Fragment {

  /** What each platform usually has, used when asked about an exec platform that is not this one. */
  private static final ImmutableMap<OS, PathFragment> DECLARED =
      ImmutableMap.of(
          OS.WINDOWS, PathFragment.create("c:/msys64/usr/bin/bash.exe"),
          OS.FREEBSD, PathFragment.create("/usr/local/bin/bash"),
          OS.OPENBSD, PathFragment.create("/usr/local/bin/bash"),
          OS.LINUX, PathFragment.create("/bin/bash"),
          OS.DARWIN, PathFragment.create("/bin/bash"),
          OS.UNKNOWN, PathFragment.create("/bin/sh"));

  /**
   * Where a bash may be found, in the order they are tried. /bin/bash is where Linux and macOS
   * keep one; /usr/local/bin/bash is where the FreeBSD and OpenBSD ports put it; the last is
   * MSYS2 on Windows, which is the only platform here with no /bin/sh to fall back to.
   */
  private static final ImmutableList<PathFragment> BASH_CANDIDATES =
      ImmutableList.of(
          PathFragment.create("/bin/bash"),
          PathFragment.create("/usr/local/bin/bash"),
          PathFragment.create("c:/msys64/usr/bin/bash.exe"));

  /** Present on every system Bazel runs on except Windows. */
  private static final PathFragment POSIX_SHELL = PathFragment.create("/bin/sh");

  private static Function<Options, PathFragment> optionsBasedDefault;

  /**
   * Injects a function for retrieving the default sh path from build options, and a map for
   * locating the correct sh executable given a set of target constraints.
   */
  public static void injectShellExecutableFinder(
      Function<Options, PathFragment> shellFromOptionsFinder) {
    // It'd be nice not to have to set a global static field. But there are so many disparate calls
    // to getShellExecutables() (in both the build's analysis phase and in the run command) that
    // feeding this through instance variables is unwieldy. Fortunately this info is a function of
    // the Blaze implementation and not something that might change between builds.
    optionsBasedDefault = shellFromOptionsFinder;
  }

  @Nullable private final PathFragment defaultShellExecutableFromOptions;

  public ShellConfiguration(BuildOptions buildOptions) {
    this.defaultShellExecutableFromOptions =
        optionsBasedDefault.apply(buildOptions.get(Options.class));
  }

  public static Optional<PathFragment> getShellExecutable(OS os) {
    // Only for the machine this is running on. os can describe a different exec platform, and
    // what is installed here says nothing about what is installed there, so for anything else
    // keep naming the path that platform usually has.
    if (os != OS.getCurrent()) {
      return Optional.ofNullable(DECLARED.get(os));
    }
    for (PathFragment candidate : BASH_CANDIDATES) {
      if (new File(candidate.getPathString()).canExecute()) {
        return Optional.of(candidate);
      }
    }
    // No bash anywhere. On Windows there is no /bin/sh either, but Bazel needs MSYS2 there in
    // any case, so the last candidate above is what a working install has.
    return os == OS.WINDOWS ? Optional.empty() : Optional.of(POSIX_SHELL);
  }

  /* Returns the default shell from build options if set explicitly. */
  @Nullable
  PathFragment getOptionsBasedDefault() {
    return defaultShellExecutableFromOptions;
  }

  /** An option that tells Bazel where the shell is. */
  @OptionsClass
  public abstract static class Options extends FragmentOptions {
    @Option(
        name = "shell_executable",
        converter = PathFragmentConverter.class,
        defaultValue = "null",
        documentationCategory = OptionDocumentationCategory.UNCATEGORIZED,
        effectTags = {OptionEffectTag.LOADING_AND_ANALYSIS},
        help =
            """
            Absolute path to the shell executable for Bazel to use. If this is unset, but the
            `BAZEL_SH` environment variable is set on the first Bazel invocation (that starts
            up a Bazel server), Bazel uses that. If neither is set, Bazel uses a hard-coded
            default path depending on the operating system it runs on;
            - Windows: `c:/msys64/usr/bin/bash.exe`
            - FreeBSD and OpenBSD: `/usr/local/bin/bash`
            - All others: `/bin/bash`.

            Note that using a shell that is not compatible with `bash` may lead
            to build failures or runtime failures of the generated binaries.
            """)
    public abstract PathFragment getShellExecutable();

    public abstract void setShellExecutable(PathFragment value);
  }
}
