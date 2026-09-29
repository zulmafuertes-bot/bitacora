# Backend privado para Bitácora Biblia

La app conserva `localStorage` cuando no hay sesión. Con Supabase configurado, las entradas nuevas se sincronizan al espacio compartido y cada una queda atribuida al usuario autenticado. Las tablas usan Row Level Security; la clave secreta de Gemini solo se usa dentro de la Edge Function.

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

## 3. Configurar Gemini y desplegar la función

Crea una API key en [Google AI Studio](https://aistudio.google.com/apikey). En Supabase Dashboard, abre Edge Functions > Secrets y agrega `GEMINI_API_KEY` junto con `APP_ORIGIN`. Guarda la clave directamente en el panel; no la pongas en `index.html`, `supabase-config.js`, GitHub ni mensajes. El nivel gratuito de Gemini tiene límites de uso y Google puede usar las solicitudes para mejorar sus productos; no envíes notas sensibles. Revisa los [precios y límites vigentes](https://ai.google.dev/gemini-api/docs/pricing).

La app usa `gemini-2.5-flash` por defecto; `GEMINI_MODEL` es opcional. Para la app publicada, `APP_ORIGIN` debe ser `https://zulmafuertes-bot.github.io` (sin `/bitacora/`). La función permite un solo origen a la vez; cámbialo a `http://localhost:8000` solo durante pruebas locales. El botón **Infografía** permite elegir formato, estilo visual y paleta; arma un prompt local con la cita y las notas para feed vertical, cuadrado, historia/Reel, horizontal, video o Pinterest. La app no solicita la imagen ni comparte esas notas por sí sola: copia el prompt y pégalo en Gemini o ChatGPT. El uso de imágenes depende de los límites y condiciones del servicio que elijas.

```powershell
npx supabase functions deploy ai-study
```

Supabase inyecta las variables `SUPABASE_URL` y la clave pública para el runtime de la función.

Para ejecución local de funciones, crea `supabase/functions/.env` basándote en `supabase/functions/.env.example` y usa `npx supabase start` y `npx supabase functions serve ai-study`. El archivo real `.env` está excluido de Git. `supabase start` necesita Docker.

## 4. Crear y compartir la bitácora

### Acceso con Google (Gmail)

1. En [Google Cloud Console](https://console.cloud.google.com/), crea o selecciona un proyecto y configura **Google Auth Platform** (pantalla de consentimiento). Para probar en modo externo, agrega los dos Gmail como usuarios de prueba.
2. Crea un cliente OAuth de tipo **Web application**. En **Authorized redirect URIs**, agrega exactamente `https://etiabkqqhxjezuzrrkrp.supabase.co/auth/v1/callback`.
3. En Supabase, abre Authentication > Sign In / Providers > Google. Activa Google y pega allí el **Client ID** y el **Client Secret** de Google. Guárdalos solo en los paneles oficiales; no en el repositorio ni en esta conversación.
4. La app ya permite **Continuar con Google**. El primer acceso crea automáticamente el usuario de Supabase; el segundo Gmail debe iniciar con su propia cuenta de Google.

La URL de retorno de la app ya está permitida en Supabase: `https://zulmafuertes-bot.github.io/bitacora/`. Si pruebas en local, permite también `http://localhost:8000/`.

### Compartir la bitácora

1. Abre la app y crea el primer usuario o continúa con Google.
2. Inicia sesión y pulsa **Crear nuestra bitácora compartida**.
3. Escribe el correo de tu esposa y crea la invitación. La app genera un código de un solo uso que vence en siete días; compártelo por un canal privado.
4. Tu esposa inicia con Google usando el Gmail invitado. Después pega el código para unirse.
5. Antes de migrar, conserva el JSON de respaldo. En Ajustes, usa **Importar registros locales** para copiar el historial de este dispositivo al espacio. La importación omite duplicados; el JSON descargado sigue siendo otra copia de respaldo.

Cada fila de `entries` guarda `created_by`, `updated_by`, `entry_date`, `type` y `data`. En el historial se muestra quién creó la entrada. Un miembro del espacio puede editar o borrar entradas compartidas; la atribución del autor original no se puede cambiar.

## Privacidad y límites

Las notas que envíes con los botones de análisis se transmiten a Google Gemini. La función no las escribe en otra tabla y limita cada cuenta a 100 solicitudes diarias; las cuotas gratuitas de Gemini dependen del modelo, proyecto y nivel, y pueden ser menores. Google limita por proyecto y puede devolver un error `429` cuando se alcanza la cuota. El prompt de imagen solo se transmite al proveedor externo si lo pegas allí. El uso de IA no elimina automáticamente las licencias de traducciones bíblicas: confirma que la fuente y versión seleccionadas permiten el uso que necesitas.

El respaldo JSON puede incluir oraciones y otra información personal. Guárdalo en un lugar privado. Los borradores sin guardar y las preferencias locales no se suben al historial compartido. Las etiquetas siguen siendo locales en esta primera versión.
