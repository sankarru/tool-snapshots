import org.objectweb.asm.*;
import java.io.*;
import java.nio.file.*;
import java.util.zip.*;

public class Patch {
 public static void main(String[] args) throws Exception {
  String src = args[0];
  String dst = src + ".tmp";
  ZipFile zin = new ZipFile(src);
  ZipOutputStream zout = new ZipOutputStream(new FileOutputStream(dst));
  byte[] patched = null;
  String patchedEntry = null;
  for (var e : java.util.Collections.list(zin.entries())) {
   InputStream in = zin.getInputStream(e);
   byte[] data = in.readAllBytes();
   final String entryName = e.getName();
   final boolean isPathUtil = entryName.equals("org/jetbrains/kotlin/utils/PathUtil.class");
   final boolean isCompanion = entryName.equals("org/jetbrains/kotlin/cli/jvm/compiler/KotlinCoreEnvironment$Companion.class");
   final boolean isCoreEnv = entryName.equals("com/intellij/core/CoreApplicationEnvironment.class");
   final boolean isJvmScripting = entryName.equals("kotlin/script/experimental/jvm/JvmScriptingHostConfigurationKt.class");
   if (isPathUtil || isCompanion || isCoreEnv || isJvmScripting) {
    System.out.println("patching " + entryName);
    ClassReader cr = new ClassReader(data);
    ClassWriter cw = new ClassWriter(ClassWriter.COMPUTE_MAXS | ClassWriter.COMPUTE_FRAMES) {
     @Override protected String getCommonSuperClass(String t1, String t2) {
      try { return super.getCommonSuperClass(t1, t2); } catch (Exception ex) { return "java/lang/Object"; }
     }
    };
     ClassVisitor cv = new ClassVisitor(Opcodes.ASM9, cw) {
      @Override public MethodVisitor visitMethod(int access, String name, String desc, String sig, String[] ex) {
       if (isJvmScripting && name.equals("<clinit>") && desc.equals("()V")) {
        System.out.println("patching JvmScriptingHostConfigurationKt clinit for java.home null");
        MethodVisitor mv = cw.visitMethod(access, name, desc, sig, ex);
        return new MethodVisitor(Opcodes.ASM9, mv) {
         boolean seenLdcJavaHome = false;
         @Override public void visitLdcInsn(Object value) {
          if ("java.home".equals(value)) seenLdcJavaHome = true;
          super.visitLdcInsn(value);
         }
         @Override public void visitMethodInsn(int opcode, String owner, String name, String desc, boolean itf) {
          if (seenLdcJavaHome && owner.equals("java/lang/System") && name.equals("getProperty") && desc.equals("(Ljava/lang/String;)Ljava/lang/String;")) {
           super.visitMethodInsn(opcode, owner, name, desc, itf);
           super.visitInsn(Opcodes.DUP);
           Label notNull = new Label();
           super.visitJumpInsn(Opcodes.IFNONNULL, notNull);
           super.visitInsn(Opcodes.POP);
           super.visitLdcInsn("");
           super.visitLabel(notNull);
           seenLdcJavaHome = false;
           return;
          }
          super.visitMethodInsn(opcode, owner, name, desc, itf);
         }
        };
       }
       if (isPathUtil && name.equals("getResourcePathForClass") && desc.equals("(Ljava/lang/Class;)Ljava/io/File;")) {
       System.out.println("found PathUtil method, replacing");
       MethodVisitor mv = cw.visitMethod(access, name, desc, sig, ex);
       mv.visitCode();
       mv.visitVarInsn(Opcodes.ALOAD, 0);
       mv.visitLdcInsn("aClass");
       mv.visitMethodInsn(Opcodes.INVOKESTATIC, "kotlin/jvm/internal/Intrinsics", "checkNotNullParameter", "(Ljava/lang/Object;Ljava/lang/String;)V", false);
       mv.visitTypeInsn(Opcodes.NEW, "java/lang/StringBuilder");
       mv.visitInsn(Opcodes.DUP);
       mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/StringBuilder", "<init>", "()V", false);
       mv.visitIntInsn(Opcodes.BIPUSH, 47);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/StringBuilder", "append", "(C)Ljava/lang/StringBuilder;", false);
       mv.visitVarInsn(Opcodes.ALOAD, 0);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/Class", "getName", "()Ljava/lang/String;", false);
       mv.visitIntInsn(Opcodes.BIPUSH, 46);
       mv.visitIntInsn(Opcodes.BIPUSH, 47);
       mv.visitInsn(Opcodes.ICONST_0);
       mv.visitIntInsn(Opcodes.BIPUSH, 4);
       mv.visitInsn(Opcodes.ACONST_NULL);
       mv.visitMethodInsn(Opcodes.INVOKESTATIC, "kotlin/text/StringsKt", "replace$default", "(Ljava/lang/String;CCZILjava/lang/Object;)Ljava/lang/String;", false);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/StringBuilder", "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;", false);
       mv.visitLdcInsn(".class");
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/StringBuilder", "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;", false);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/StringBuilder", "toString", "()Ljava/lang/String;", false);
       mv.visitVarInsn(Opcodes.ASTORE, 1);
       mv.visitVarInsn(Opcodes.ALOAD, 0);
       mv.visitVarInsn(Opcodes.ALOAD, 1);
       mv.visitMethodInsn(Opcodes.INVOKESTATIC, "com/intellij/openapi/application/PathManager", "getResourceRoot", "(Ljava/lang/Class;Ljava/lang/String;)Ljava/lang/String;", false);
       mv.visitVarInsn(Opcodes.ASTORE, 2);
       mv.visitVarInsn(Opcodes.ALOAD, 2);
       Label notNull = new Label();
       mv.visitJumpInsn(Opcodes.IFNONNULL, notNull);
       mv.visitLdcInsn("kotlin.home");
       mv.visitMethodInsn(Opcodes.INVOKESTATIC, "java/lang/System", "getProperty", "(Ljava/lang/String;)Ljava/lang/String;", false);
       mv.visitVarInsn(Opcodes.ASTORE, 3);
       mv.visitVarInsn(Opcodes.ALOAD, 3);
       Label khNotNull = new Label();
       mv.visitJumpInsn(Opcodes.IFNULL, khNotNull);
       mv.visitVarInsn(Opcodes.ALOAD, 3);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/String", "isEmpty", "()Z", false);
       mv.visitJumpInsn(Opcodes.IFNE, khNotNull);
       mv.visitTypeInsn(Opcodes.NEW, "java/io/File");
       mv.visitInsn(Opcodes.DUP);
       mv.visitVarInsn(Opcodes.ALOAD, 3);
       mv.visitLdcInsn("/lib/kotlin-compiler.jar");
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;", false);
       mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/io/File", "<init>", "(Ljava/lang/String;)V", false);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/io/File", "getAbsoluteFile", "()Ljava/io/File;", false);
       mv.visitInsn(Opcodes.ARETURN);
       mv.visitLabel(khNotNull);
       mv.visitLdcInsn("java.home");
       mv.visitMethodInsn(Opcodes.INVOKESTATIC, "java/lang/System", "getProperty", "(Ljava/lang/String;)Ljava/lang/String;", false);
       mv.visitVarInsn(Opcodes.ASTORE, 4);
       mv.visitVarInsn(Opcodes.ALOAD, 4);
       Label jhNotNull = new Label();
       mv.visitJumpInsn(Opcodes.IFNULL, jhNotNull);
       mv.visitTypeInsn(Opcodes.NEW, "java/io/File");
       mv.visitInsn(Opcodes.DUP);
       mv.visitVarInsn(Opcodes.ALOAD, 4);
       mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/io/File", "<init>", "(Ljava/lang/String;)V", false);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/io/File", "getAbsoluteFile", "()Ljava/io/File;", false);
       mv.visitInsn(Opcodes.ARETURN);
       mv.visitLabel(jhNotNull);
       mv.visitTypeInsn(Opcodes.NEW, "java/io/File");
       mv.visitInsn(Opcodes.DUP);
       mv.visitLdcInsn("");
       mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/io/File", "<init>", "(Ljava/lang/String;)V", false);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/io/File", "getAbsoluteFile", "()Ljava/io/File;", false);
       mv.visitInsn(Opcodes.ARETURN);
       mv.visitLabel(notNull);
       mv.visitTypeInsn(Opcodes.NEW, "java/io/File");
       mv.visitInsn(Opcodes.DUP);
       mv.visitVarInsn(Opcodes.ALOAD, 2);
       mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/io/File", "<init>", "(Ljava/lang/String;)V", false);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/io/File", "getAbsoluteFile", "()Ljava/io/File;", false);
       mv.visitInsn(Opcodes.ARETURN);
       mv.visitMaxs(0,0);
       mv.visitEnd();
       return null;
      }
      if (isCoreEnv && name.equals("registerExtensionPointAndExtensions") && desc.equals("(Ljava/nio/file/Path;Ljava/lang/String;Lcom/intellij/openapi/extensions/ExtensionsArea;)V")) {
       System.out.println("patching CoreApplicationEnvironment.registerExtensionPointAndExtensions to no-op (extensions already in image via IncludeResources)");
       MethodVisitor mv = cw.visitMethod(access, name, desc, sig, ex);
       mv.visitCode();
       mv.visitInsn(Opcodes.RETURN);
       mv.visitMaxs(0,3);
       mv.visitEnd();
       return null;
      }
      if (isCompanion && name.equals("registerApplicationExtensionPointsAndExtensionsFrom$hasConfigFile") && desc.equals("(Ljava/io/File;Ljava/lang/String;)Z")) {
       System.out.println("patching hasConfigFile to check via ClassLoader resource");
       MethodVisitor mv = cw.visitMethod(access, name, desc, sig, ex);
       mv.visitCode();
       // return Thread.currentThread().getContextClassLoader().getResourceAsStream("META-INF/" + path) != null
       // with fallback to ClassLoader.getSystemClassLoader()
       mv.visitMethodInsn(Opcodes.INVOKESTATIC, "java/lang/Thread", "currentThread", "()Ljava/lang/Thread;", false);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/Thread", "getContextClassLoader", "()Ljava/lang/ClassLoader;", false);
       mv.visitVarInsn(Opcodes.ASTORE, 2);
       mv.visitVarInsn(Opcodes.ALOAD, 2);
       Label hasCL = new Label();
       mv.visitJumpInsn(Opcodes.IFNONNULL, hasCL);
       mv.visitMethodInsn(Opcodes.INVOKESTATIC, "java/lang/ClassLoader", "getSystemClassLoader", "()Ljava/lang/ClassLoader;", false);
       mv.visitVarInsn(Opcodes.ASTORE, 2);
       mv.visitLabel(hasCL);
       mv.visitVarInsn(Opcodes.ALOAD, 2);
       mv.visitTypeInsn(Opcodes.NEW, "java/lang/StringBuilder");
       mv.visitInsn(Opcodes.DUP);
       mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/StringBuilder", "<init>", "()V", false);
       mv.visitLdcInsn("META-INF/");
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/StringBuilder", "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;", false);
       mv.visitVarInsn(Opcodes.ALOAD, 1);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/StringBuilder", "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;", false);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/StringBuilder", "toString", "()Ljava/lang/String;", false);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/ClassLoader", "getResourceAsStream", "(Ljava/lang/String;)Ljava/io/InputStream;", false);
       Label notNull = new Label();
       Label isTrue = new Label();
       mv.visitJumpInsn(Opcodes.IFNONNULL, isTrue);
       mv.visitInsn(Opcodes.ICONST_0);
       mv.visitJumpInsn(Opcodes.GOTO, notNull);
       mv.visitLabel(isTrue);
       mv.visitInsn(Opcodes.ICONST_1);
       mv.visitLabel(notNull);
       mv.visitInsn(Opcodes.IRETURN);
       mv.visitMaxs(3,3);
       mv.visitEnd();
       return null;
      }
      return super.visitMethod(access, name, desc, sig, ex);
     }
    };
    cr.accept(cv, 0);
    patched = cw.toByteArray();
    patchedEntry = entryName;
    System.out.println("patched size " + patched.length + " for " + entryName);
   }
   ZipEntry ne = new ZipEntry(e.getName());
   ne.setTime(e.getTime());
   zout.putNextEntry(ne);
   if (patched != null && e.getName().equals(patchedEntry)) {
    zout.write(patched);
    patched = null;
    patchedEntry = null;
   } else {
    zout.write(data);
   }
   zout.closeEntry();
  }
  zout.close();
  zin.close();
  Files.move(Paths.get(dst), Paths.get(src), StandardCopyOption.REPLACE_EXISTING);
  System.out.println("done");
 }
}
