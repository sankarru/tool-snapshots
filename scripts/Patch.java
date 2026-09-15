import org.objectweb.asm.*;
import org.objectweb.asm.tree.*;
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
  for (var e : java.util.Collections.list(zin.entries())) {
   InputStream in = zin.getInputStream(e);
   byte[] data = in.readAllBytes();
   if (e.getName().equals("org/jetbrains/kotlin/utils/PathUtil.class")) {
    System.out.println("patching PathUtil");
    ClassReader cr = new ClassReader(data);
    ClassWriter cw = new ClassWriter(ClassWriter.COMPUTE_MAXS | ClassWriter.COMPUTE_FRAMES);
    ClassVisitor cv = new ClassVisitor(Opcodes.ASM9, cw) {
     @Override public MethodVisitor visitMethod(int access, String name, String desc, String sig, String[] ex) {
      if (name.equals("getResourcePathForClass") && desc.equals("(Ljava/lang/Class;)Ljava/io/File;")) {
       System.out.println("found method, replacing");
       MethodVisitor mv = cw.visitMethod(access, name, desc, sig, ex);
       mv.visitCode();
       // if (aClass == null) checkNotNullParameter
       mv.visitVarInsn(Opcodes.ALOAD, 0);
       mv.visitLdcInsn("aClass");
       mv.visitMethodInsn(Opcodes.INVOKESTATIC, "kotlin/jvm/internal/Intrinsics", "checkNotNullParameter", "(Ljava/lang/Object;Ljava/lang/String;)V", false);
       // String path = "/" + aClass.getName().replace('.', '/') + ".class"
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
       // String root = PathManager.getResourceRoot(aClass, path)
       mv.visitVarInsn(Opcodes.ALOAD, 0);
       mv.visitVarInsn(Opcodes.ALOAD, 1);
       mv.visitMethodInsn(Opcodes.INVOKESTATIC, "com/intellij/openapi/application/PathManager", "getResourceRoot", "(Ljava/lang/Class;Ljava/lang/String;)Ljava/lang/String;", false);
       mv.visitVarInsn(Opcodes.ASTORE, 2);
       mv.visitVarInsn(Opcodes.ALOAD, 2);
       Label notNull = new Label();
       mv.visitJumpInsn(Opcodes.IFNONNULL, notNull);
       // fallback: String kh = System.getProperty("kotlin.home")
       mv.visitLdcInsn("kotlin.home");
       mv.visitMethodInsn(Opcodes.INVOKESTATIC, "java/lang/System", "getProperty", "(Ljava/lang/String;)Ljava/lang/String;", false);
       mv.visitVarInsn(Opcodes.ASTORE, 3);
       mv.visitVarInsn(Opcodes.ALOAD, 3);
       Label khNotNull = new Label();
       mv.visitJumpInsn(Opcodes.IFNULL, khNotNull);
       mv.visitVarInsn(Opcodes.ALOAD, 3);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/String", "isEmpty", "()Z", false);
       mv.visitJumpInsn(Opcodes.IFNE, khNotNull);
       // return new File(kh + "/lib/kotlin-compiler.jar").getAbsoluteFile()
       mv.visitTypeInsn(Opcodes.NEW, "java/io/File");
       mv.visitInsn(Opcodes.DUP);
       mv.visitVarInsn(Opcodes.ALOAD, 3);
       mv.visitLdcInsn("/lib/kotlin-compiler.jar");
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;", false);
       mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/io/File", "<init>", "(Ljava/lang/String;)V", false);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/io/File", "getAbsoluteFile", "()Ljava/io/File;", false);
       mv.visitInsn(Opcodes.ARETURN);
       mv.visitLabel(khNotNull);
       // try java.home
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
       // return new File("").getAbsoluteFile()
       mv.visitTypeInsn(Opcodes.NEW, "java/io/File");
       mv.visitInsn(Opcodes.DUP);
       mv.visitLdcInsn("");
       mv.visitMethodInsn(Opcodes.INVOKESPECIAL, "java/io/File", "<init>", "(Ljava/lang/String;)V", false);
       mv.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/io/File", "getAbsoluteFile", "()Ljava/io/File;", false);
       mv.visitInsn(Opcodes.ARETURN);
       mv.visitLabel(notNull);
       // original success path: new File(root).getAbsoluteFile()
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
      return super.visitMethod(access, name, desc, sig, ex);
     }
    };
    cr.accept(cv, 0);
    patched = cw.toByteArray();
    System.out.println("patched size " + patched.length);
   }
   ZipEntry ne = new ZipEntry(e.getName());
   ne.setTime(e.getTime());
   zout.putNextEntry(ne);
   if (patched != null && e.getName().equals("org/jetbrains/kotlin/utils/PathUtil.class")) {
    zout.write(patched);
    patched = null;
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
