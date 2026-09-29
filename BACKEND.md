# Backend privado para Bitácora Biblia

La app conserva `localStorage` cuando no hay sesión. Con Supabase configurado, las entradas nuevas se sincronizan al espacio compartido y cada una queda atribuida al usuario autenticado. Las tablas usan Row Level Security; las claves secretas de OpenAI solo se usan dentro de la Edge Function.

## 1. Crear el proyecto

1. Crea un proyecto en [Supabase](https://supabase.com/dashboard).
2. En Authentication > URL Configuration, agrega el origen de la app a Site URL y Redirect URLs. Para la prueba local usa `http://localhost:8000`.
3. En Project Settings > API copia Project URL y la clave pública `anon` (o la publishable key).
4. Coloca esos dos valores en `supabase-config.js`. Esa clave pública está diseñada para el navegador; no uses aquí `service_role` ni una secret key.

```js
window.BITACORA_SUPABASE_CONFIG = {
    url: 'https://TU-PROJECT-REF.supabase.co',
    anonKey: 'TU-CLAVE-PUBLICA'
};
```

## 2. Crear las tablas y políticas

Instala Supabase CLI siguiendo [la guía oficial](https://supabase.com/docs/guides/cli) y, desde la raíz de este proyecto, ejecuta:

```powershell
npx supabase login
npx supabase link --project-ref TU-PROJECT-REF
npx supabase db push
```

`db push` crea perfiles, espacios, invitaciones, registros, índices, funciones y políticas RLS a partir de `supabase/migrations/20260929000000_initial.sql`.

## 3. Configurar OpenAI y desplegar la función

Crea una API key de OpenAI desde su plataforma. No la pongas en `index.html`, `supabase-config.js`, ni la compartas en mensajes o comandos que queden en el historial de PowerShell. En Supabase Dashboard, abre Edge Functions > Secrets y agrega `OPENAI_API_KEY`, `OPENAI_MODEL`, `OPENAI_IMAGE_MODEL` y `APP_ORIGIN` (`http://localhost:8000` en local). Configura la clave secreta directamente en el panel; nunca la envíes por este chat.

```powershell
npx supabase functions deploy ai-study
```

Cuando publiques la app, cambia `APP_ORIGIN` por el origen exacto del sitio, por ejemplo `https://tu-dominio.example`, y vuelve a guardar el secreto. Supabase inyecta las variables `SUPABASE_URL` y la clave pública para el runtime de la función.

Para ejecución local de funciones, crea `supabase/functions/.env` basándote en `supabase/functions/.env.example` y usa `npx supabase start` y `npx supabase functions serve ai-study`. El archivo real `.env` está excluido de Git. `supabase start` necesita Docker.

## 4. Crear y compartir la bitácora

1. Abre la app desde el origen configurado, crea una cuenta con tu correo y confirma el mensaje de Supabase si la confirmación está activada.
2. Inicia sesión y pulsa **Crear nuestra bitácora compartida**.
3. Escribe el correo de tu esposa y crea la invitación. La app genera un código de un solo uso que vence en siete días; compártelo por un canal privado.
4. Ella debe crear su cuenta con ese mismo correo, confirmarla e iniciar sesión. Después pega el código para unirse.
5. Antes de migrar, conserva el JSON de respaldo. En Ajustes, usa **Importar registros locales** para copiar el historial de este dispositivo al espacio. La importación omite duplicados; el JSON descargado sigue siendo otra copia de respaldo.

Cada fila de `entries` guarda `created_by`, `updated_by`, `entry_date`, `type` y `data`. En el historial se muestra quién creó la entrada. Un miembro del espacio puede editar o borrar entradas compartidas; la atribución del autor original no se puede cambiar.

## Privacidad y límites

Las notas que envíes con los botones de IA se transmiten a OpenAI. La función usa `store: false`, no escribe las notas en otra tabla y limita cada cuenta a 30 solicitudes diarias. El uso personal puede ser no comercial, pero no elimina automáticamente las licencias de traducciones bíblicas: confirma que la fuente y versión seleccionadas permiten el uso que necesitas.

El respaldo JSON puede incluir oraciones y otra información personal. Guárdalo en un lugar privado. Los borradores sin guardar y las preferencias locales no se suben al historial compartido. Las etiquetas siguen siendo locales en esta primera versión.
