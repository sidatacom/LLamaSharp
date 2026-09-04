using LLama.Abstractions;
using System.Collections.Generic;

namespace LLama.Native;

#if NET6_0_OR_GREATER
/// <summary>
/// A native library compiled with the llama.cpp SYCL backend.
/// </summary>
public sealed class NativeLibraryWithSycl : INativeLibrary
{
    private readonly NativeLibraryName libraryName;
    private readonly AvxLevel avxLevel;
    private readonly bool skipCheck;

    /// <inheritdoc />
    public NativeLibraryMetadata? Metadata => new(libraryName, false, false, avxLevel, true);

    /// <summary>
    /// Creates a SYCL native library selector.
    /// </summary>
    public NativeLibraryWithSycl(NativeLibraryName libraryName, AvxLevel avxLevel, bool skipCheck)
    {
        this.libraryName = libraryName;
        this.avxLevel = avxLevel;
        this.skipCheck = skipCheck;
    }

    /// <inheritdoc />
    public IEnumerable<string> Prepare(SystemInfo systemInfo, NativeLogConfig.LLamaLogCallback? logCallback)
    {
        if (systemInfo.OSPlatform == OSPlatform.Windows || systemInfo.OSPlatform == OSPlatform.Linux || skipCheck)
        {
            NativeLibraryUtils.GetPlatformPathParts(systemInfo.OSPlatform, out var os, out var fileExtension, out var libPrefix);
            yield return $"runtimes/{os}/native/sycl/{libPrefix}{libraryName.GetLibraryName()}{fileExtension}";
        }
    }
}
#endif