// Edge Function: crear-colaborador
// Crea el login de un colaborador y su carnet en un solo paso.
// Solo puede ejecutarla un usuario cuyo perfil tenga rol = 'admin'.
// Despliegue: supabase functions deploy crear-colaborador
// (SUPABASE_URL, SUPABASE_ANON_KEY y SUPABASE_SERVICE_ROLE_KEY
// ya están disponibles automáticamente dentro de la función)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function fail(msg: string, status = 400) {
  return new Response(JSON.stringify({ error: msg }), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const supabaseUrl = Deno.env.get("https://tqkapzhszgykwdrjonza.supabase.co")!;
    const anonKey = Deno.env.get("sb_publishable_n18qRbCf8nBsJDXAZSxEfQ_ZCo1-i4y")!;
    const serviceKey = Deno.env.get("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRxa2Fwemhzemd5a3dkcmpvbnphIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc5MDYxMzkzNiwiZXhwIjoyMTA2MTg5OTM2fQ.qftr6Ky3l4Fc3ekyGLgri0UNe1xh4fNB4LdPCG013Gc")!;

    // 1. Identificar quién llama, con su propio token (no con privilegios de admin todavía)
    const authHeader = req.headers.get("Authorization") ?? "";
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !user) return fail("No autenticado.", 401);

    // 2. Confirmar que quien llama es admin
    const { data: perfil, error: perfilErr } = await callerClient
      .from("profiles").select("rol").eq("id", user.id).single();
    if (perfilErr || perfil?.rol !== "admin") {
      return fail("Solo un administrador puede crear colaboradores.", 403);
    }

    // 3. Leer y validar los datos del nuevo colaborador
    const { email, password, nombre_completo, cargo } = await req.json();
    if (!email || !password || !nombre_completo || !cargo) {
      return fail("Faltan campos: correo, contraseña, nombre y cargo son obligatorios.");
    }
    if (String(password).length < 8) {
      return fail("La contraseña debe tener al menos 8 caracteres.");
    }

    // 4. Cliente con privilegios totales — solo existe en el servidor, nunca en el navegador
    const admin = createClient(supabaseUrl, serviceKey);

    const { data: creado, error: createErr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
    });
    if (createErr) return fail("No se pudo crear el usuario: " + createErr.message);

    const nuevoId = creado.user.id;

    const { error: profileErr } = await admin.from("profiles").insert({
      id: nuevoId, email, nombre_completo, rol: "colaborador",
    });
    if (profileErr) {
      await admin.auth.admin.deleteUser(nuevoId);
      return fail("No se pudo crear el perfil: " + profileErr.message);
    }

    const { data: carnet, error: carnetErr } = await admin
      .from("empleados_carnets")
      .insert({ nombre_completo, cargo, user_id: nuevoId })
      .select().single();
    if (carnetErr) {
      await admin.auth.admin.deleteUser(nuevoId);
      return fail("No se pudo emitir el carnet: " + carnetErr.message);
    }

    return new Response(JSON.stringify({ carnet }), {
      status: 200,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  } catch (e) {
    return fail("Error inesperado: " + (e as Error).message, 500);
  }
});
