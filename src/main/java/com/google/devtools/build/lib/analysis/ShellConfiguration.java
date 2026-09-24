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
import java.util.Map;
import java.util.Optional;
import java.util.function.Function;
import javax.annotation.Nullable;

/** A configuration fragment that tells where the shell is. */
@RequiresOptions(options = {ShellConfiguration.Options.class})
public class ShellConfiguration extends Fragment {

  private static Map<OS, PathFragment> shellExecutables;

  private static Function<Options, PathFragment> optionsBasedDefault;

  /**
   * Injects a function for retrieving the default sh path from build options, and a map for
   * locating the correct sh executable given a set of target constraints.
   */
  public static void injectShellExecutableFinder(
      Function<Options, PathFragment> shellFromOptionsFinder, Map<OS, PathFragment> osToShellMap) {
    // It'd be nice not to have to set a global static field. But there are so many disparate calls
    // to getShellExecutables() (in both the build's analysis phase and in the run command) that
    // feeding this through instance variables is unwieldy. Fortunately this info is a function of
    // the Blaze implementation and not something that might change between builds.
    optionsBasedDefault = shellFromOptionsFinder;
    shellExecutables = osToShellMap;
  }

  @Nullable private final PathFragment defaultShellExecutableFromOptions;

  public ShellConfiguration(BuildOptions buildOptions) {
    this.defaultShellExecutableFromOptions =
        optionsBasedDefault.apply(buildOptions.get(Options.class));
  }

  /**
   * The shell to use where the one named for the platform is not installed. Every system Bazel
   * runs on other than Windows has /bin/sh; not all of them have a bash.
   */
  private static final PathFragment POSIX_SHELL = PathFragment.create("/bin/sh");

  public static Optional<PathFragment> getShellExecutable(OS os) {
    PathFragment shell = shellExecutables.get(os);
    if (shell == null) {
      return Optional.empty();
    }
    // The map names a bash, and on three of the five platforms in it that is a path a package
    // manager provides rather than the system: MSYS2 on Windows, ports on the BSDs. On Linux it
    // is /bin/bash, which the distributions carrying bash as an essential package have and an
    // Alpine image does not have at all. Where that bash is not installed, use the shell that is.
    // Windows is left alone: there is no /bin/sh there to fall back to.
    // Only for the machine this is running on. os can describe a different exec platform -- the
    // TODO in BazelRuleClassProvider.getShellExecutableForOs is about exactly that -- and what is
    // or is not installed here says nothing about what is installed there. Windows is left alone
    // as well: there is no /bin/sh there to fall back to.
    if (os != OS.getCurrent() || os == OS.WINDOWS || shell.equals(POSIX_SHELL)) {
      return Optional.of(shell);
    }
    return Optional.of(new File(shell.getPathString()).canExecute() ? shell : POSIX_SHELL);
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
