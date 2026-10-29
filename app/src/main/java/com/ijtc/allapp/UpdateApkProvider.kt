package com.ijtc.allapp

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

class UpdateApkProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String? {
        requireApkUri(uri)
        return "application/vnd.android.package-archive"
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val apk = requireApkUri(uri)
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns).apply {
            addRow(
                columns.map { column ->
                    when (column) {
                        OpenableColumns.DISPLAY_NAME -> apk.name
                        OpenableColumns.SIZE -> apk.length()
                        else -> null
                    }
                }
            )
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Update APK is read-only.")
        return ParcelFileDescriptor.open(requireApkUri(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? =
        throw UnsupportedOperationException("Update APK provider is read-only.")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("Update APK provider is read-only.")

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = throw UnsupportedOperationException("Update APK provider is read-only.")

    private fun requireApkUri(uri: Uri): File {
        if (uri.pathSegments != listOf(APK_FILE_NAME)) {
            throw FileNotFoundException("Unknown update APK.")
        }
        val apk = File(requireNotNull(context).cacheDir, APK_FILE_NAME)
        if (!apk.isFile) throw FileNotFoundException("Update APK is not available.")
        return apk
    }

    private companion object {
        const val APK_FILE_NAME = "allapp-update.apk"
    }
}
